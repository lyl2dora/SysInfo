// Top N（CPU 模块设计 §5.7，边界稿 §5.3，D31）。
//
// - 按应用：一个 coalition 一行，按窗口内 CPU 降序；
//   行名依次取：最外层 .app 的成员（同级取最早启动的）→ 最早启动的成员；pid 0 显示 kernel_task；
//   宿主 coalition（终端、Xcode）副标题给占用最高的同 uid 成员；
//   展开：同 uid 成员用 rusage 精确拆分，外部成员只能归入残差，残差只在窗口内成员没有变化时才算（钳到 ≥0）；
// - 按进程：单成员 coalition 直接是一个进程；多成员的拆成同 uid 成员，外部成员合成一个分不开的组行；
// - 名称按开机期间唯一 id 缓存（PROC_PIDUNIQIDENTIFIERINFO），pid 复用不会张冠李戴；
// - 只为排在前面的 coalition 读成员和进程信息，扫描本身由 AppSampler 完成。

import Darwin
import Foundation
import Synchronization
import SysModel

/// 进程表的一项（`KERN_PROC_ALL`，公开 API）。
public struct ProcessEntry: Hashable, Sendable {
    public var pid: pid_t
    public var uid: uid_t
    /// 启动时刻，微秒（Unix 时间）。
    public var startMicros: UInt64
    /// `p_comm`（最多 16 字节，可能被截断）。
    public var command: String
}

public enum ProcessTable {
    /// 一次取全部进程（0.07–0.4 ms）。
    public static func snapshot() -> [pid_t: ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [:] }
        var out: [pid_t: ProcessEntry] = [:]
        for info in buffer.prefix(size / stride) {
            let pid = info.kp_proc.p_pid
            let start = UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000 + UInt64(info.kp_proc.p_starttime.tv_usec)
            let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            out[pid] = ProcessEntry(pid: pid, uid: info.kp_eproc.e_ucred.cr_uid, startMicros: start, command: command)
        }
        return out
    }
}

/// 结束进程（D31）：只对同 uid 的进程；root、其他用户、SysInfo 自身一律不允许，不提权（D04）。
/// GUI app 的优雅退出（NSRunningApplication.terminate）由 app 层处理；这里是通用的信号路径。
public enum ProcessControl {
    public static func eligibility(uid: uid_t?, pid: pid_t, ownUID: uid_t = getuid(), ownPID: pid_t = getpid())
        -> TerminationEligibility
    {
        if pid == ownPID { return .isSelf }
        guard let uid else { return .unknown }
        if uid == 0 || pid <= 1 { return .root }
        return uid == ownUID ? .allowed : .otherUser
    }

    public enum TerminateError: Error, Hashable, Sendable {
        case notAllowed(TerminationEligibility)
        case signalFailed(errno: Int32)
    }

    /// 发 SIGTERM（`force` 时 SIGKILL）。调用前在 UI 上确认。
    public static func terminate(pid: pid_t, force: Bool) throws(TerminateError) {
        let e = eligibility(uid: ProcessInfoReader.uid(of: pid), pid: pid)
        guard e.isAllowed else { throw .notAllowed(e) }
        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else { throw .signalFailed(errno: errno) }
    }
}

/// 由 AppSampler 的窗口生成 Top N 行。持有名称缓存和同 uid 成员的上一次 rusage，同一时刻只由一个调用方使用。
public final class TopNBuilder: Sendable {
    /// 进程的显示名：所在 .app 的名字，或可执行文件名。
    public struct NameInfo: Hashable, Sendable {
        public var name: String
        public var appPath: String?
        public var path: String?
    }

    private struct State {
        /// 唯一 id → 名称。
        var names: [UInt64: NameInfo] = [:]
        /// 唯一 id → (rusage CPU tick, 读取时的单调时钟纳秒)。
        var memberCPU: [UInt64: (ticks: UInt64, nanos: UInt64)] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// - Parameters:
    ///   - rows: 行数（0/3/5/8/10）。
    ///   - showPerfLevel0: 是否给 perflevel0 占比（两档芯片、拓扑成立、槽位可信时由调用方打开）。
    public func build(
        window: AppActivityWindow, rows: Int, grouping: TopNGrouping, showPerfLevel0: Bool, slotsTrusted: Bool
    ) -> [TopNRow] {
        guard rows > 0 else { return [] }
        let table = ProcessTable.snapshot()
        let elapsed = Double(window.elapsedNanos)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // 按进程视图里一个多成员 coalition 会拆成多行，所以多看一些 coalition。
        let candidates = window.coalitions.prefix(grouping == .byApp ? rows : rows * 3)
        var out: [TopNRow] = []
        for delta in candidates where delta.cpuNanos > 0 {
            let pids = CoalitionReader.members(of: delta.id, tasksHint: Int(delta.tasks)) ?? []
            let row = coalitionRow(
                delta, pids: pids, table: table, elapsed: elapsed, now: now, showPerfLevel0: showPerfLevel0,
                slotsTrusted: slotsTrusted)
            switch grouping {
            case .byApp:
                out.append(row)
            case .byProcess:
                out.append(contentsOf: processRows(from: row))
            }
        }
        if grouping == .byProcess { out.sort { $0.cpu > $1.cpu } }
        pruneCaches(alive: Set(table.keys))
        return Array(out.prefix(rows))
    }

    private func coalitionRow(
        _ delta: CoalitionDelta, pids: [pid_t], table: [pid_t: ProcessEntry], elapsed: Double, now: UInt64,
        showPerfLevel0: Bool, slotsTrusted: Bool
    ) -> TopNRow {
        let ownUID = getuid()
        let entries = pids.compactMap { table[$0] }
        // 代表成员：最外层 .app 里的成员优先，同级取最早启动的；没有 .app 时取最早启动的。
        let infos: [(ProcessEntry, NameInfo)] = entries.map { ($0, name(of: $0)) }
        let inApp = infos.filter { $0.1.appPath != nil }
        let representative: (ProcessEntry, NameInfo)? =
            (inApp.isEmpty ? infos : inApp).min { $0.0.startMicros < $1.0.startMicros }
        let cpu = Double(delta.cpuNanos) / elapsed

        var members: [TopNMember] = []
        var sameUIDCPU = 0.0
        var allMeasured = true
        for (entry, info) in infos where entry.uid == ownUID {
            let memberCPU = measure(pid: entry.pid, now: now)
            if let memberCPU { sameUIDCPU += memberCPU } else { allMeasured = false }
            members.append(
                TopNMember(
                    pid: entry.pid, name: info.name, path: info.path, cpu: memberCPU,
                    eligibility: ProcessControl.eligibility(uid: entry.uid, pid: entry.pid)))
        }
        members.sort { ($0.cpu ?? -1) > ($1.cpu ?? -1) }
        let foreign = entries.count - members.count
        let residual: Double? =
            foreign > 0 && !delta.membershipChanged && allMeasured ? max(cpu - sameUIDCPU, 0) : nil
        let top = members.first.flatMap { m -> TopNMember? in
            guard entries.count > 1, m.pid != representative?.0.pid, (m.cpu ?? 0) > 0 else { return nil }
            return m
        }
        let repPID = representative?.0.pid ?? pids.first ?? 0
        let isKernel = pids.contains(0)
        let eligibility: TerminationEligibility =
            entries.count == 1 ? ProcessControl.eligibility(uid: entries[0].uid, pid: entries[0].pid) : .group
        return TopNRow(
            id: "c\(delta.id)", kind: .coalition, coalitionID: delta.id,
            name: isKernel ? "kernel_task" : (representative?.1.name ?? "cid \(delta.id)"),
            appPath: representative?.1.appPath, representativePID: repPID, memberCount: max(pids.count, Int(delta.tasks)),
            cpu: cpu,
            perfLevel0Share: showPerfLevel0 && delta.cpuNanos > 0 ? Double(delta.perfLevel0Nanos) / Double(delta.cpuNanos) : nil,
            energyWatts: slotsTrusted ? Double(delta.energyNanojoules) / elapsed : nil, topMember: top, members: members,
            residualCPU: residual, residualCount: foreign, eligibility: eligibility)
    }

    /// 按进程视图：单成员 coalition 就是一个进程；多成员的拆成同 uid 成员，外部成员合成一个组行。
    private func processRows(from row: TopNRow) -> [TopNRow] {
        if row.memberCount <= 1 {
            var single = row
            single.kind = .process
            single.id = "p\(row.representativePID)"
            return [single]
        }
        var out: [TopNRow] = row.members.compactMap { m in
            guard let cpu = m.cpu, cpu > 0 else { return nil }
            return TopNRow(
                id: "p\(m.pid)", kind: .process, coalitionID: row.coalitionID, name: m.name, appPath: nil,
                representativePID: m.pid, memberCount: 1, cpu: cpu, perfLevel0Share: nil, energyWatts: nil, topMember: nil,
                members: [], residualCPU: nil, residualCount: 0, eligibility: m.eligibility)
        }
        if row.residualCount > 0 {
            let measured = out.reduce(0) { $0 + $1.cpu }
            out.append(
                TopNRow(
                    id: "g\(row.coalitionID)", kind: .group, coalitionID: row.coalitionID, name: row.name,
                    appPath: row.appPath, representativePID: row.representativePID, memberCount: row.residualCount,
                    cpu: row.residualCPU ?? max(row.cpu - measured, 0), perfLevel0Share: nil, energyWatts: nil,
                    topMember: nil, members: [], residualCPU: nil, residualCount: row.residualCount, eligibility: .group))
        }
        return out
    }

    // MARK: - 缓存

    private func name(of entry: ProcessEntry) -> NameInfo {
        let unique = ProcessPrivateInfo.uniqueID(of: entry.pid)
        if let unique, let hit = state.withLock({ $0.names[unique] }) { return hit }
        let path = ProcessInfoReader.path(of: entry.pid)
        let info = Self.resolveName(path: path, command: entry.command, pid: entry.pid)
        if let unique { state.withLock { $0.names[unique] = info } }
        return info
    }

    public static func resolveName(path: String?, command: String, pid: pid_t) -> NameInfo {
        if pid == 0 { return NameInfo(name: "kernel_task", appPath: nil, path: nil) }
        guard let path else { return NameInfo(name: command.isEmpty ? "pid \(pid)" : command, appPath: nil, path: nil) }
        if let app = outermostApp(in: path) {
            let bundle = Bundle(path: app)
            let display =
                (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return NameInfo(name: display, appPath: app, path: path)
        }
        return NameInfo(name: (path as NSString).lastPathComponent, appPath: nil, path: path)
    }

    /// 路径里最外层的 `.app` 目录。
    static func outermostApp(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// 同 uid 成员在两次 build 之间的 CPU（按单核比例）；第一次见到时只记基线。
    private func measure(pid: pid_t, now: UInt64) -> Double? {
        guard let unique = ProcessPrivateInfo.uniqueID(of: pid), let r = ProcessInfoReader.rusage(of: pid),
            let timebase = MachTimebase.current
        else { return nil }
        let ticks = r.ri_user_time + r.ri_system_time
        return state.withLock { s in
            defer { s.memberCPU[unique] = (ticks, now) }
            guard let previous = s.memberCPU[unique], now > previous.nanos, ticks >= previous.ticks else { return nil }
            return Double(timebase.nanoseconds(fromTicks: ticks - previous.ticks)) / Double(now - previous.nanos)
        }
    }

    /// 只保留还活着的进程的缓存（按 pid 粗略判断，唯一 id 缓存随之变小）。
    private func pruneCaches(alive: Set<pid_t>) {
        state.withLock { s in
            if s.names.count > 4096 { s.names.removeAll(keepingCapacity: true) }
            if s.memberCPU.count > 4096 { s.memberCPU.removeAll(keepingCapacity: true) }
        }
        _ = alive
    }
}
