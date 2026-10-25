// Top N（CPU 模块设计 §5.7，边界稿 §5.3，D31）。
//
// - 按应用：一个 coalition 一行，按窗口内 CPU 降序；
//   行名依次取：最外层 .app 的成员（同级取最早启动的）→ 最早启动的成员；pid 0 显示 kernel_task；
//   宿主 coalition（终端、Xcode）副标题给占用最高的同 uid 成员；
//   展开：同 uid 成员用 rusage 精确拆分，外部成员只能归入残差，残差只在窗口内成员没有变化时才算（钳到 ≥0）；
// - 按进程：单成员 coalition 直接是一个进程；多成员的拆成同 uid 成员，外部成员合成一个分不开的组行；
// - 内存（D49）：按 coalition 的 footprint（slot 40，成员之和）排序，同 uid 成员用 `ri_phys_footprint` 拆分，
//   外部成员合计 = coalition 合计 − 同 uid 之和（footprint 是当前值，不涉及窗口内成员变化）；
// - 磁盘（存储模块设计 §4.5）：按 coalition 6/7 号槽（累计读写字节，含 root 成员）的窗口差分排序；
//   同 uid 成员用 `ri_diskio_bytesread/written` 差分拆分，外部成员归入残差（只在窗口内成员没有变化时才算，钳到 ≥0）；
// - GPU（D57 G7）：按 coalition 槽位 8（GPU 时间）的窗口差分排序，附槽位 41（GPU 能耗）与 39（ANE 能耗）。
//   没有按进程的公开 GPU 计数，成员只列名字不拆数值；按进程视图里多成员 coalition 保持一行；
// - 同 uid 成员的 CPU 与磁盘按 coalition 窗口差分：基线记在所属窗口上，只有上一次基线正好是紧邻的前一个窗口时
//   才出数，分母用窗口长度，与 coalition 的值同口径（rusage 在组装时读，比扫描晚几毫秒，前后两端偏移相同）；
//   跳过窗口、面板关了很久后重开时，这一轮只记基线；
// - 名称按开机期间唯一 id 缓存（PROC_PIDUNIQIDENTIFIERINFO），pid 复用不会张冠李戴；缓存按存活的 pid 清理；
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

    /// 成员差分所属的 coalition 窗口。
    struct MemberWindow {
        /// 窗口结束（扫描）时的单调时钟纳秒。
        var end: UInt64
        var elapsed: UInt64
        var start: UInt64 { end &- elapsed }

        init(_ window: AppActivityWindow) {
            end = window.time.monotonicNanos
            elapsed = window.elapsedNanos
        }
    }

    private struct MemberCPU {
        var pid: pid_t
        var ticks: UInt64
        var windowEnd: UInt64
        /// 这个窗口算出的值：同一个窗口再组装一次（面板重开时复用最近的窗口）时直接用它。
        var rate: Double?
    }

    private struct MemberDisk {
        var pid: pid_t
        var read: UInt64
        var written: UInt64
        var windowEnd: UInt64
        var rate: (read: Double, write: Double)?
    }

    private struct State {
        /// 唯一 id → 名称（连同 pid，清理用）。
        var names: [UInt64: (pid: pid_t, info: NameInfo)] = [:]
        /// 唯一 id → 上一次的 rusage CPU tick。
        var memberCPU: [UInt64: MemberCPU] = [:]
        /// 唯一 id → 上一次的 rusage 磁盘读、写字节。
        var memberDisk: [UInt64: MemberDisk] = [:]
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
        let span = MemberWindow(window)
        // 按进程视图里一个多成员 coalition 会拆成多行，所以多看一些 coalition。
        let candidates = window.coalitions.prefix(grouping == .byApp ? rows : rows * 3)
        var out: [TopNRow] = []
        for delta in candidates where delta.cpuNanos > 0 {
            let pids = CoalitionReader.members(of: delta.id, tasksHint: Int(delta.tasks)) ?? []
            let row = coalitionRow(
                delta, pids: pids, table: table, elapsed: elapsed, span: span, showPerfLevel0: showPerfLevel0,
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
        _ delta: CoalitionDelta, pids: [pid_t], table: [pid_t: ProcessEntry], elapsed: Double, span: MemberWindow,
        showPerfLevel0: Bool, slotsTrusted: Bool
    ) -> TopNRow {
        let ownUID = getuid()
        let entries = pids.compactMap { table[$0] }
        let infos: [(ProcessEntry, NameInfo)] = entries.map { ($0, name(of: $0)) }
        let representative = Self.representative(infos)
        let cpu = Double(delta.cpuNanos) / elapsed

        var members: [TopNMember] = []
        var sameUIDCPU = 0.0
        var allMeasured = true
        for (entry, info) in infos where entry.uid == ownUID {
            let memberCPU = measure(pid: entry.pid, span: span)
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

    /// 代表成员：最外层 .app 里的成员优先，同级取最早启动的；没有 .app 时取最早启动的。
    static func representative(_ infos: [(ProcessEntry, NameInfo)]) -> (ProcessEntry, NameInfo)? {
        let inApp = infos.filter { $0.1.appPath != nil }
        return (inApp.isEmpty ? infos : inApp).min { $0.0.startMicros < $1.0.startMicros }
    }

    // MARK: - 内存（D49）

    /// 按内存 footprint 生成 Top N 行。footprint 是当前值，一次扫描就够，不需要差分。
    public func buildMemory(footprints: CoalitionFootprints, rows: Int, grouping: TopNGrouping) -> [TopNRow] {
        guard rows > 0 else { return [] }
        let table = ProcessTable.snapshot()
        let candidates = footprints.coalitions.prefix(grouping == .byApp ? rows : rows * 3)
        var out: [TopNRow] = []
        for coalition in candidates where coalition.bytes > 0 {
            let pids = CoalitionReader.members(of: coalition.id, tasksHint: Int(coalition.tasks)) ?? []
            let row = memoryRow(coalition, pids: pids, table: table)
            switch grouping {
            case .byApp: out.append(row)
            case .byProcess: out.append(contentsOf: memoryProcessRows(from: row))
            }
        }
        if grouping == .byProcess { out.sort { ($0.footprint ?? 0) > ($1.footprint ?? 0) } }
        pruneCaches(alive: Set(table.keys))
        return Array(out.prefix(rows))
    }

    private func memoryRow(_ coalition: CoalitionFootprint, pids: [pid_t], table: [pid_t: ProcessEntry]) -> TopNRow {
        let ownUID = getuid()
        let entries = pids.compactMap { table[$0] }
        let infos: [(ProcessEntry, NameInfo)] = entries.map { ($0, name(of: $0)) }
        let representative = Self.representative(infos)
        var members: [TopNMember] = []
        var sameUID: UInt64 = 0
        for (entry, info) in infos where entry.uid == ownUID {
            let bytes = ProcessInfoReader.rusage(of: entry.pid)?.ri_phys_footprint
            sameUID &+= bytes ?? 0
            members.append(
                TopNMember(
                    pid: entry.pid, name: info.name, path: info.path, cpu: nil,
                    eligibility: ProcessControl.eligibility(uid: entry.uid, pid: entry.pid), footprint: bytes))
        }
        members.sort { ($0.footprint ?? 0) > ($1.footprint ?? 0) }
        let foreign = entries.count - members.count
        let top = members.first.flatMap { m -> TopNMember? in
            guard entries.count > 1, m.pid != representative?.0.pid, (m.footprint ?? 0) > 0 else { return nil }
            return m
        }
        let isKernel = pids.contains(0)
        return TopNRow(
            id: "c\(coalition.id)", kind: .coalition, coalitionID: coalition.id,
            name: isKernel ? "kernel_task" : (representative?.1.name ?? "cid \(coalition.id)"),
            appPath: representative?.1.appPath, representativePID: representative?.0.pid ?? pids.first ?? 0,
            memberCount: max(pids.count, Int(coalition.tasks)), cpu: 0, perfLevel0Share: nil, energyWatts: nil,
            topMember: top, members: members, residualCPU: nil, residualCount: foreign,
            eligibility: entries.count == 1 ? ProcessControl.eligibility(uid: entries[0].uid, pid: entries[0].pid) : .group,
            footprint: coalition.bytes,
            residualFootprint: foreign > 0 ? (coalition.bytes > sameUID ? coalition.bytes - sameUID : 0) : nil)
    }

    /// 按进程视图（内存）：单成员 coalition 就是一个进程；多成员的拆成同 uid 成员，外部成员合成一个组行。
    private func memoryProcessRows(from row: TopNRow) -> [TopNRow] {
        if row.memberCount <= 1 {
            var single = row
            single.kind = .process
            single.id = "p\(row.representativePID)"
            return [single]
        }
        var out: [TopNRow] = row.members.compactMap { m in
            guard let bytes = m.footprint, bytes > 0 else { return nil }
            return TopNRow(
                id: "p\(m.pid)", kind: .process, coalitionID: row.coalitionID, name: m.name,
                appPath: m.path.flatMap(Self.outermostApp(in:)), representativePID: m.pid, memberCount: 1, cpu: 0,
                perfLevel0Share: nil, energyWatts: nil, topMember: nil, members: [], residualCPU: nil, residualCount: 0,
                eligibility: m.eligibility, footprint: bytes)
        }
        if row.residualCount > 0, let residual = row.residualFootprint, residual > 0 {
            out.append(
                TopNRow(
                    id: "g\(row.coalitionID)", kind: .group, coalitionID: row.coalitionID, name: row.name,
                    appPath: row.appPath, representativePID: row.representativePID, memberCount: row.residualCount, cpu: 0,
                    perfLevel0Share: nil, energyWatts: nil, topMember: nil, members: [], residualCPU: nil,
                    residualCount: row.residualCount, eligibility: .group, footprint: residual))
        }
        return out
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
                id: "p\(m.pid)", kind: .process, coalitionID: row.coalitionID, name: m.name,
                appPath: m.path.flatMap(Self.outermostApp(in:)),
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

    // MARK: - 磁盘（存储模块设计 §4.5）

    /// 按窗口内的磁盘读 + 写生成 Top N 行。
    public func buildDisk(window: AppActivityWindow, rows: Int, grouping: TopNGrouping) -> [TopNRow] {
        guard rows > 0 else { return [] }
        let table = ProcessTable.snapshot()
        let elapsed = Double(window.elapsedNanos)
        guard elapsed > 0 else { return [] }
        let span = MemberWindow(window)
        let sorted = window.coalitions
            .filter { $0.diskReadBytes > 0 || $0.diskWrittenBytes > 0 }
            .sorted { $0.diskReadBytes &+ $0.diskWrittenBytes > $1.diskReadBytes &+ $1.diskWrittenBytes }
        var out: [TopNRow] = []
        for delta in sorted.prefix(grouping == .byApp ? rows : rows * 3) {
            let pids = CoalitionReader.members(of: delta.id, tasksHint: Int(delta.tasks)) ?? []
            let row = diskRow(delta, pids: pids, table: table, elapsed: elapsed, span: span)
            switch grouping {
            case .byApp: out.append(row)
            case .byProcess: out.append(contentsOf: diskProcessRows(from: row))
            }
        }
        if grouping == .byProcess { out.sort { $0.diskTotal > $1.diskTotal } }
        pruneCaches(alive: Set(table.keys))
        return Array(out.prefix(rows))
    }

    private func diskRow(
        _ delta: CoalitionDelta, pids: [pid_t], table: [pid_t: ProcessEntry], elapsed: Double, span: MemberWindow
    ) -> TopNRow {
        let ownUID = getuid()
        let entries = pids.compactMap { table[$0] }
        let infos: [(ProcessEntry, NameInfo)] = entries.map { ($0, name(of: $0)) }
        let representative = Self.representative(infos)
        let seconds = elapsed / 1e9
        let read = Double(delta.diskReadBytes) / seconds
        let write = Double(delta.diskWrittenBytes) / seconds
        var members: [TopNMember] = []
        var sameRead = 0.0
        var sameWrite = 0.0
        var allMeasured = true
        for (entry, info) in infos where entry.uid == ownUID {
            let io = measureDisk(pid: entry.pid, span: span)
            if let io {
                sameRead += io.read
                sameWrite += io.write
            } else {
                allMeasured = false
            }
            members.append(
                TopNMember(
                    pid: entry.pid, name: info.name, path: info.path, cpu: nil,
                    eligibility: ProcessControl.eligibility(uid: entry.uid, pid: entry.pid), diskRead: io?.read,
                    diskWrite: io?.write))
        }
        members.sort { ($0.diskRead ?? 0) + ($0.diskWrite ?? 0) > ($1.diskRead ?? 0) + ($1.diskWrite ?? 0) }
        let foreign = entries.count - members.count
        let residualKnown = foreign > 0 && !delta.membershipChanged && allMeasured
        let top = members.first.flatMap { m -> TopNMember? in
            guard entries.count > 1, m.pid != representative?.0.pid, (m.diskRead ?? 0) + (m.diskWrite ?? 0) > 0 else { return nil }
            return m
        }
        let isKernel = pids.contains(0)
        return TopNRow(
            id: "c\(delta.id)", kind: .coalition, coalitionID: delta.id,
            name: isKernel ? "kernel_task" : (representative?.1.name ?? "cid \(delta.id)"),
            appPath: representative?.1.appPath, representativePID: representative?.0.pid ?? pids.first ?? 0,
            memberCount: max(pids.count, Int(delta.tasks)), cpu: 0, perfLevel0Share: nil, energyWatts: nil, topMember: top,
            members: members, residualCPU: nil, residualCount: foreign,
            eligibility: entries.count == 1 ? ProcessControl.eligibility(uid: entries[0].uid, pid: entries[0].pid) : .group,
            diskRead: read, diskWrite: write, residualDiskRead: residualKnown ? max(read - sameRead, 0) : nil,
            residualDiskWrite: residualKnown ? max(write - sameWrite, 0) : nil)
    }

    /// 按进程视图（磁盘）：单成员 coalition 就是一个进程；多成员的拆成同 uid 成员，外部成员合成一个组行。
    private func diskProcessRows(from row: TopNRow) -> [TopNRow] {
        if row.memberCount <= 1 {
            var single = row
            single.kind = .process
            single.id = "p\(row.representativePID)"
            return [single]
        }
        var out: [TopNRow] = row.members.compactMap { m in
            guard (m.diskRead ?? 0) + (m.diskWrite ?? 0) > 0 else { return nil }
            return TopNRow(
                id: "p\(m.pid)", kind: .process, coalitionID: row.coalitionID, name: m.name,
                appPath: m.path.flatMap(Self.outermostApp(in:)), representativePID: m.pid, memberCount: 1, cpu: 0,
                perfLevel0Share: nil, energyWatts: nil, topMember: nil, members: [], residualCPU: nil, residualCount: 0,
                eligibility: m.eligibility, diskRead: m.diskRead, diskWrite: m.diskWrite)
        }
        if row.residualCount > 0 {
            let measuredRead = out.reduce(0) { $0 + ($1.diskRead ?? 0) }
            let measuredWrite = out.reduce(0) { $0 + ($1.diskWrite ?? 0) }
            let read = row.residualDiskRead ?? max((row.diskRead ?? 0) - measuredRead, 0)
            let write = row.residualDiskWrite ?? max((row.diskWrite ?? 0) - measuredWrite, 0)
            if read + write > 0 {
                out.append(
                    TopNRow(
                        id: "g\(row.coalitionID)", kind: .group, coalitionID: row.coalitionID, name: row.name,
                        appPath: row.appPath, representativePID: row.representativePID, memberCount: row.residualCount, cpu: 0,
                        perfLevel0Share: nil, energyWatts: nil, topMember: nil, members: [], residualCPU: nil,
                        residualCount: row.residualCount, eligibility: .group, diskRead: read, diskWrite: write))
            }
        }
        return out
    }

    /// 同 uid 成员在这个窗口里的磁盘读写（B/s）；上一次基线不是紧邻的前一个窗口时只记基线。
    func measureDisk(pid: pid_t, span: MemberWindow?) -> (read: Double, write: Double)? {
        guard let span, span.elapsed > 0, let unique = ProcessPrivateInfo.uniqueID(of: pid),
            let r = ProcessInfoReader.rusage(of: pid)
        else { return nil }
        let read = r.ri_diskio_bytesread
        let written = r.ri_diskio_byteswritten
        return state.withLock { s in
            let previous = s.memberDisk[unique]
            if let previous, previous.windowEnd == span.end { return previous.rate }
            var rate: (read: Double, write: Double)?
            if let previous, previous.windowEnd == span.start, read >= previous.read, written >= previous.written {
                let seconds = Double(span.elapsed) / 1e9
                rate = (Double(read - previous.read) / seconds, Double(written - previous.written) / seconds)
            }
            s.memberDisk[unique] = MemberDisk(pid: pid, read: read, written: written, windowEnd: span.end, rate: rate)
            return rate
        }
    }

    // MARK: - GPU（D57 G7）

    /// 按窗口内的 GPU 时间生成 Top N 行。GPU 时间为 0 但有 ANE 能耗的也列出（排在 GPU 之后，按 ANE 能耗）。
    public func buildGPU(window: AppActivityWindow, rows: Int, grouping: TopNGrouping) -> [TopNRow] {
        guard rows > 0 else { return [] }
        let table = ProcessTable.snapshot()
        let elapsed = Double(window.elapsedNanos)
        guard elapsed > 0 else { return [] }
        let sorted = window.coalitions
            .filter { $0.gpuNanos > 0 || $0.aneEnergyNanojoules > 0 }
            .sorted { a, b in
                a.gpuNanos != b.gpuNanos ? a.gpuNanos > b.gpuNanos : a.aneEnergyNanojoules > b.aneEnergyNanojoules
            }
        var out: [TopNRow] = []
        for delta in sorted.prefix(rows) {
            let pids = CoalitionReader.members(of: delta.id, tasksHint: Int(delta.tasks)) ?? []
            var row = gpuRow(delta, pids: pids, table: table, elapsed: elapsed, trusted: window.slotsTrusted)
            if grouping == .byProcess, row.memberCount <= 1 {
                row.kind = .process
                row.id = "p\(row.representativePID)"
            }
            out.append(row)
        }
        pruneCaches(alive: Set(table.keys))
        return out
    }

    private func gpuRow(
        _ delta: CoalitionDelta, pids: [pid_t], table: [pid_t: ProcessEntry], elapsed: Double, trusted: Bool
    ) -> TopNRow {
        let ownUID = getuid()
        let entries = pids.compactMap { table[$0] }
        let infos: [(ProcessEntry, NameInfo)] = entries.map { ($0, name(of: $0)) }
        let representative = Self.representative(infos)
        let seconds = elapsed / 1e9
        let members: [TopNMember] = infos.filter { $0.0.uid == ownUID }.map { entry, info in
            TopNMember(
                pid: entry.pid, name: info.name, path: info.path, cpu: nil,
                eligibility: ProcessControl.eligibility(uid: entry.uid, pid: entry.pid))
        }
        let isKernel = pids.contains(0)
        return TopNRow(
            id: "c\(delta.id)", kind: .coalition, coalitionID: delta.id,
            name: isKernel ? "kernel_task" : (representative?.1.name ?? "cid \(delta.id)"),
            appPath: representative?.1.appPath, representativePID: representative?.0.pid ?? pids.first ?? 0,
            memberCount: max(pids.count, Int(delta.tasks)), cpu: 0, perfLevel0Share: nil, energyWatts: nil, topMember: nil,
            members: members, residualCPU: nil, residualCount: entries.count - members.count,
            eligibility: entries.count == 1 ? ProcessControl.eligibility(uid: entries[0].uid, pid: entries[0].pid) : .group,
            // 辅助槽不可信时 GPU / ANE 都不给数（D96）。
            gpuShare: trusted ? Double(delta.gpuNanos) / elapsed : nil,
            gpuWatts: trusted ? Double(delta.gpuEnergyNanojoules) / 1e9 / seconds : nil,
            aneWatts: trusted ? Double(delta.aneEnergyNanojoules) / 1e9 / seconds : nil)
    }

    // MARK: - 应用详情（D64）

    /// 一个 coalition 的应用详情：各域的值取自同一个窗口与最近一次 footprint 扫描；成员是全部同 uid 进程，
    /// 每个成员都量 CPU、footprint 与磁盘读写（成员 CPU 与磁盘第一次见到时只记基线，为 nil）。
    /// coalition 已经没有成员（应用退出）时返回 nil。
    public func detail(
        coalitionID: UInt64, window: AppActivityWindow?, footprints: CoalitionFootprints?, slotsTrusted: Bool
    ) -> AppDetail? {
        let delta = window?.coalitions.first { $0.id == coalitionID }
        let footprint = footprints?.coalitions.first { $0.id == coalitionID }
        let hint = Int(delta?.tasks ?? footprint?.tasks ?? 0)
        guard let pids = CoalitionReader.members(of: coalitionID, tasksHint: hint), !pids.isEmpty else { return nil }
        let table = ProcessTable.snapshot()
        let span = window.map(MemberWindow.init)
        let ownUID = getuid()
        let entries = pids.compactMap { table[$0] }
        let infos: [(ProcessEntry, NameInfo)] = entries.map { ($0, name(of: $0)) }
        let representative = Self.representative(infos)
        var members: [TopNMember] = []
        for (entry, info) in infos where entry.uid == ownUID {
            let disk = measureDisk(pid: entry.pid, span: span)
            members.append(
                TopNMember(
                    pid: entry.pid, name: info.name, path: info.path, cpu: measure(pid: entry.pid, span: span),
                    eligibility: ProcessControl.eligibility(uid: entry.uid, pid: entry.pid),
                    footprint: ProcessInfoReader.rusage(of: entry.pid)?.ri_phys_footprint, diskRead: disk?.read,
                    diskWrite: disk?.write))
        }
        members.sort { a, b in
            (a.cpu ?? -1) != (b.cpu ?? -1) ? (a.cpu ?? -1) > (b.cpu ?? -1) : (a.footprint ?? 0) > (b.footprint ?? 0)
        }
        let elapsed = Double(window?.elapsedNanos ?? 0)
        // 还没有窗口、或本窗口没有这个 coalition 的差分（新出现、计数回退）时为 nil，显示「—」而不是 0。
        func rate(_ value: UInt64?) -> Double? {
            guard elapsed > 0, delta != nil, let value else { return nil }
            return Double(value) / elapsed
        }
        func auxiliary(_ value: UInt64?) -> Double? { slotsTrusted ? rate(value) : nil }  // D96
        let isKernel = pids.contains(0)
        pruneCaches(alive: Set(table.keys))
        return AppDetail(
            coalitionID: coalitionID, name: isKernel ? "kernel_task" : (representative?.1.name ?? "cid \(coalitionID)"),
            appPath: representative?.1.appPath, representativePID: representative?.0.pid ?? pids.first ?? 0,
            memberCount: max(pids.count, hint), cpu: rate(delta?.cpuNanos),
            energyWatts: auxiliary(delta?.energyNanojoules), footprint: footprint?.bytes,
            diskRead: rate(delta?.diskReadBytes).map { $0 * 1e9 }, diskWrite: rate(delta?.diskWrittenBytes).map { $0 * 1e9 },
            gpuShare: auxiliary(delta?.gpuNanos), gpuWatts: auxiliary(delta?.gpuEnergyNanojoules),
            aneWatts: auxiliary(delta?.aneEnergyNanojoules), members: members, residualCount: entries.count - members.count,
            eligibility: entries.count == 1 ? ProcessControl.eligibility(uid: entries[0].uid, pid: entries[0].pid) : .group)
    }

    // MARK: - 缓存

    private func name(of entry: ProcessEntry) -> NameInfo {
        let unique = ProcessPrivateInfo.uniqueID(of: entry.pid)
        if let unique, let hit = state.withLock({ $0.names[unique] }) { return hit.info }
        let path = ProcessInfoReader.path(of: entry.pid)
        let info = Self.resolveName(path: path, command: entry.command, pid: entry.pid)
        if let unique { state.withLock { $0.names[unique] = (entry.pid, info) } }
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

    /// 同 uid 成员在这个窗口里的 CPU（按单核比例）；上一次基线不是紧邻的前一个窗口时只记基线。
    func measure(pid: pid_t, span: MemberWindow?) -> Double? {
        guard let span, span.elapsed > 0, let unique = ProcessPrivateInfo.uniqueID(of: pid),
            let r = ProcessInfoReader.rusage(of: pid), let timebase = MachTimebase.current
        else { return nil }
        let ticks = r.ri_user_time + r.ri_system_time
        return state.withLock { s in
            let previous = s.memberCPU[unique]
            if let previous, previous.windowEnd == span.end { return previous.rate }
            var rate: Double?
            if let previous, previous.windowEnd == span.start, ticks >= previous.ticks {
                rate = Double(timebase.nanoseconds(fromTicks: ticks - previous.ticks)) / Double(span.elapsed)
            }
            s.memberCPU[unique] = MemberCPU(pid: pid, ticks: ticks, windowEnd: span.end, rate: rate)
            return rate
        }
    }

    /// 只保留还活着的进程的缓存（唯一 id 作键，按记下的 pid 判断存活）。
    private func pruneCaches(alive: Set<pid_t>) {
        state.withLock { s in
            s.names = s.names.filter { alive.contains($0.value.pid) }
            s.memberCPU = s.memberCPU.filter { alive.contains($0.value.pid) }
            s.memberDisk = s.memberDisk.filter { alive.contains($0.value.pid) }
        }
    }
}
