// coalition 不可用时的 Top N 回退（CPU 模块设计 §5.7，D31，修订 D05 的回退示例）。
//
// - 常规：只列同 uid 的进程（`proc_listallpids` + `proc_pid_rusage` v6，root 与其他用户的进程读不到，
//   UI 提示「另有 N 个系统或其他用户进程不可见」）；
// - 内存 Top N 的回退只列同 uid 进程的 `ri_phys_footprint`，没有「刷新全部」（`ps` 没有 footprint 列，D49）；
// - 手动「刷新全部」：间隔 2 s 运行两次 setuid 的 `/bin/ps -axo pid=,time=`，取 TIME 差分（10 ms 分辨率，覆盖除 pid 0 外的全部进程）。
//   只在用户点击时运行，不定时 spawn（CLAUDE.md）。不用 `top`：每次至少 1 s 墙钟、自身占 3–6% 单核，%CPU 还偏低。

import Darwin
import Foundation
import Synchronization
import SysModel

/// 同 uid 进程的 CPU 采样（公开 API）。
public final class SameUIDSampler: Sendable {
    private struct State {
        var previous: [pid_t: (ticks: UInt64, unique: UInt64)] = [:]
        var previousNanos: UInt64?
    }

    private let state = Mutex(State())

    public init() {}

    public struct Result: Hashable, Sendable {
        public var rows: [TopNRow]
        /// 读不到的进程数（root 与其他用户）。
        public var hiddenCount: Int
    }

    /// 两次调用之间每个同 uid 进程的 CPU；第一次调用只建立基线。
    public func sample(rows: Int) -> Result {
        let pids = Self.allPIDs()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let ownUID = getuid()
        guard let timebase = MachTimebase.current else { return Result(rows: [], hiddenCount: pids.count) }
        var current: [pid_t: (UInt64, UInt64)] = [:]
        var hidden = 0
        for pid in pids {
            guard let r = ProcessInfoReader.rusage(of: pid), ProcessInfoReader.uid(of: pid) == ownUID else {
                hidden += 1
                continue
            }
            current[pid] = (r.ri_user_time + r.ri_system_time, ProcessPrivateInfo.uniqueID(of: pid) ?? 0)
        }
        let (previous, previousNanos) = state.withLock { s in
            defer {
                s.previous = current.mapValues { (ticks: $0.0, unique: $0.1) }
                s.previousNanos = now
            }
            return (s.previous, s.previousNanos)
        }
        guard let previousNanos, now > previousNanos else { return Result(rows: [], hiddenCount: hidden) }
        let elapsed = Double(now - previousNanos)
        var out: [TopNRow] = []
        for (pid, (ticks, unique)) in current {
            guard let before = previous[pid], before.unique == unique, ticks >= before.ticks else { continue }
            let cpu = Double(timebase.nanoseconds(fromTicks: ticks - before.ticks)) / elapsed
            guard cpu > 0 else { continue }
            let path = ProcessInfoReader.path(of: pid)
            let info = TopNBuilder.resolveName(path: path, command: "", pid: pid)
            out.append(
                TopNRow(
                    id: "p\(pid)", kind: .process, coalitionID: 0, name: info.name, appPath: info.appPath,
                    representativePID: pid, memberCount: 1, cpu: cpu, perfLevel0Share: nil, energyWatts: nil, topMember: nil,
                    members: [], residualCPU: nil, residualCount: 0,
                    eligibility: ProcessControl.eligibility(uid: ownUID, pid: pid)))
        }
        out.sort { $0.cpu > $1.cpu }
        return Result(rows: Array(out.prefix(rows)), hiddenCount: hidden)
    }

    /// 同 uid 进程的内存 footprint（D49 的回退）：footprint 是当前值，不需要基线。
    public func sampleMemory(rows: Int) -> Result {
        let pids = Self.allPIDs()
        let ownUID = getuid()
        var hidden = 0
        var out: [TopNRow] = []
        for pid in pids {
            guard let r = ProcessInfoReader.rusage(of: pid), ProcessInfoReader.uid(of: pid) == ownUID else {
                hidden += 1
                continue
            }
            guard r.ri_phys_footprint > 0 else { continue }
            out.append(
                TopNRow(
                    id: "p\(pid)", kind: .process, coalitionID: 0, name: "", appPath: nil, representativePID: pid,
                    memberCount: 1, cpu: 0, perfLevel0Share: nil, energyWatts: nil, topMember: nil, members: [],
                    residualCPU: nil, residualCount: 0, eligibility: ProcessControl.eligibility(uid: ownUID, pid: pid),
                    footprint: r.ri_phys_footprint))
        }
        out.sort { ($0.footprint ?? 0) > ($1.footprint ?? 0) }
        // 只为排在前面的进程解析名字。
        let top = out.prefix(rows).map { row -> TopNRow in
            var row = row
            let info = TopNBuilder.resolveName(path: ProcessInfoReader.path(of: row.representativePID), command: "", pid: row.representativePID)
            row.name = info.name
            row.appPath = info.appPath
            return row
        }
        return Result(rows: top, hiddenCount: hidden)
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(buffer.prefix(Int(n))).filter { $0 > 0 } : []
    }
}

/// setuid `/bin/ps` 的 TIME 快照与差分（只在用户点击「刷新全部」或 `sysinfo-cli verify topn` 时运行）。
public enum PSSnapshot {
    public enum PSError: Error, Hashable, Sendable {
        case launchFailed(String)
        case exitStatus(Int32)
    }

    /// pid → 累计 CPU 秒数。
    public static func take() throws(PSError) -> [pid_t: Double] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,time="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .launchFailed("\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw .exitStatus(process.terminationStatus) }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// 解析 `pid time` 两列；TIME 形如 `0:01.23`、`12:34.56`、`1:02:03`、`2-01:02:03`。
    static func parse(_ output: String) -> [pid_t: Double] {
        var out: [pid_t: Double] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[0]), let seconds = seconds(String(fields[1])) else { continue }
            out[pid] = seconds
        }
        return out
    }

    static func seconds(_ text: String) -> Double? {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.map { $0! }
        let total = values.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + total
    }

    /// 两次快照之间每个进程的 CPU（按单核比例）。pid 复用造成的回退丢弃。
    public static func delta(_ a: [pid_t: Double], _ b: [pid_t: Double], seconds: Double) -> [pid_t: Double] {
        var out: [pid_t: Double] = [:]
        guard seconds > 0 else { return out }
        for (pid, after) in b {
            guard let before = a[pid], after >= before else { continue }
            out[pid] = (after - before) / seconds
        }
        return out
    }

    /// 手动「刷新全部」：间隔 `interval` 秒取两次快照，按 CPU 降序给出前 `rows` 个进程。
    public static func refreshAll(interval: Double = 2, rows: Int) throws(PSError) -> [TopNRow] {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let a = try take()
        usleep(UInt32(interval * 1_000_000))
        let b = try take()
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
        let table = ProcessTable.snapshot()
        return delta(a, b, seconds: elapsed).filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(rows).map {
            pid, cpu in
            let info = TopNBuilder.resolveName(path: ProcessInfoReader.path(of: pid), command: table[pid]?.command ?? "", pid: pid)
            return TopNRow(
                id: "p\(pid)", kind: .process, coalitionID: 0, name: info.name, appPath: info.appPath, representativePID: pid,
                memberCount: 1, cpu: cpu, perfLevel0Share: nil, energyWatts: nil, topMember: nil, members: [],
                residualCPU: nil, residualCount: 0,
                eligibility: ProcessControl.eligibility(uid: table[pid]?.uid, pid: pid))
        }
    }
}
