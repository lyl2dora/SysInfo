// 应用活动采集器 `app.coalition`（CPU 模块设计 §5.7，边界稿 §2.5、§7.4，D31）。走阻塞通道。
//
// - 每次全量扫描 resource coalition，按 coalition 记录两次扫描之间的增量（CPU、perflevel0 时间、cycles、能耗、成员起止数）；
// - coalition 在最后一个成员退出的同一轮就从列表里消失（边界稿 §2.5 复核），所以按 tick 累加增量：
//   消失的 coalition 只保留它消失前最后一次的增量，不补推；
// - 两次扫描之间新出现的 coalition（id 大于上次扫描见过的最大 id），它的全部用量都发生在窗口内，增量取当前累计值。
//   coalition id 单调递增；id 不大于上次最大值、上次却不在列表里的，是重新有了成员的旧 coalition
//   （launchd 周期拉起的服务，成员为 0 时不扫描）：它的累计值包含开机以来的用量，这一轮只建基线；
// - 输出的样本只有整机汇总（全体进程的 CPU、perflevel0 占比与按档频率），供被动核对使用（§5.4、§5.2）；
//   每个 coalition 的增量留在 `latestWindow`，Top N 与每应用历史从这里取。
//
// 自检（D05、K19，边界稿 §7.5，按槽位分级回退）：
// - 必需：S1 三个符号都解析到；S2 本进程所在 cid 在列表里且成员含本 pid；S3 写出 ≥400 字节且 slot 23 == 7；
// - 提示：S4 同 uid 单成员 coalition 上 slot 40 == phys_footprint、11 == energy、22 == ptime 的比例 ≥90%；
//   S5 本线程自旋 60 ms，本 coalition 的 Δ槽 24–30 与 Δrusage 一致（±2%，只在本 coalition 只有本进程一个成员时判定）。
//   S4/S5 不过：照常出数，状态降级（能耗、perflevel0 等对应列由消费者隐藏）。

import Darwin
import Synchronization
import SysModel

/// 一个 coalition 在一个窗口内的增量。
public struct CoalitionDelta: Hashable, Sendable {
    public var id: UInt64
    public var tasks: UInt32
    /// CPU 时间，纳秒。
    public var cpuNanos: UInt64
    /// perflevel0 上的 CPU 时间，纳秒。
    public var perfLevel0Nanos: UInt64
    public var cycles: UInt64
    public var perfLevel0Cycles: UInt64
    public var energyNanojoules: UInt64
    /// 磁盘读 / 写字节（存储模块设计 §4.5）。
    public var diskReadBytes: UInt64 = 0
    public var diskWrittenBytes: UInt64 = 0
    /// GPU 时间（纳秒）、GPU 能耗（nJ）、ANE 时间（纳秒）、ANE 能耗（nJ）（GPU 模块设计 §5，D57、D58）。
    public var gpuNanos: UInt64 = 0
    public var gpuEnergyNanojoules: UInt64 = 0
    public var aneNanos: UInt64 = 0
    public var aneEnergyNanojoules: UInt64 = 0
    /// 唤醒次数（槽位 4 + 5）、pageins（槽位 49）（应用活动，D67）。
    public var wakeups: UInt64 = 0
    public var pageins: UInt64 = 0
    /// 窗口结束时的当前值：footprint（槽位 40，字节）与开机以来的累计 CPU 时间（纳秒）（应用活动，D67）。
    public var footprintBytes: UInt64 = 0
    public var cpuTotalNanos: UInt64 = 0
    /// 窗口内成员有没有变化（tasks_started / tasks_exited 变了）。残差归因只在没有变化时做（边界稿 §5.3）。
    public var membershipChanged: Bool
    /// 窗口开始时还不存在（新出现的 coalition）。
    public var isNew: Bool
}

/// 一个 coalition 当前的内存 footprint（成员 `phys_footprint` 之和，slot 40，D49）。
public struct CoalitionFootprint: Hashable, Sendable {
    public var id: UInt64
    public var tasks: UInt32
    public var bytes: UInt64
}

/// 一次扫描时全部有成员的 coalition 的 footprint，按字节降序。footprint 是当前值，不需要差分，第一次扫描就有。
public struct CoalitionFootprints: Hashable, Sendable {
    public var time: SampleTime
    public var coalitions: [CoalitionFootprint]
}

/// 一次扫描得到的窗口。
public struct AppActivityWindow: Hashable, Sendable {
    public var time: SampleTime
    /// 窗口长度，纳秒（两次扫描的单调时钟之差）。
    public var elapsedNanos: UInt64
    /// 按 CPU 时间降序。
    public var coalitions: [CoalitionDelta]
    /// 扫描时能耗、perflevel0 等辅助槽是否可信（自检 S4）。
    public var slotsTrusted: Bool = true

    public var totalCPUNanos: UInt64 { coalitions.reduce(0) { $0 &+ $1.cpuNanos } }
    /// 全部 coalition 的 CPU + GPU + ANE 能耗之和，nJ（应用活动的「应用合计」，D67）。
    public var totalEnergyNanojoules: UInt64 {
        coalitions.reduce(0) { $0 &+ $1.energyNanojoules &+ $1.gpuEnergyNanojoules &+ $1.aneEnergyNanojoules }
    }
    /// 全部 coalition 的 ANE 能耗之和，nJ（ANE 功率估算，D58）。
    public var totalANEEnergyNanojoules: UInt64 { coalitions.reduce(0) { $0 &+ $1.aneEnergyNanojoules } }
}

public final class AppSampler: Collector {
    public static let collectorID: CollectorID = "app.coalition"
    public static let dataPath = "proc_listcoalitions + coalition_info_resource_usage (slots 24–30)"

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking

    private struct State {
        var previous: [UInt64: CoalitionUsage] = [:]
        /// 上次扫描见过的最大 coalition id（含成员为 0 的）。
        var previousMaxID: UInt64?
        var previousTime: SampleTime?
        var latest: AppActivityWindow?
        var footprints: CoalitionFootprints?
        var usable: Bool?
        var warnings = false
        /// S4 不过：能耗、perflevel0 槽不可信。
        var slotsTrusted = true
        /// 是否为历史记录留存窗口（`setRetainsWindows`）。
        var retainsWindows = false
        var retained: [AppActivityWindow] = []
    }

    /// 留存窗口的上限：取走的一方跟不上时丢弃最旧的。10 s 一次时约 10 分钟。
    static let retainedWindowLimit = 64

    private let state = Mutex(State())
    /// ANE 估算的对账账本（D58）：每个窗口的槽位 39 合计记进去，PMGR 批次到来时核对。
    public let ledger: PowerLedger?

    public init(ledger: PowerLedger? = nil) {
        self.ledger = ledger
    }

    /// 最近一个窗口；还没有两次扫描时为 nil。
    public var latestWindow: AppActivityWindow? { state.withLock { $0.latest } }

    /// 最近一次扫描的各 coalition 内存 footprint（内存 Top N，D49）；还没扫描过时为 nil。
    public var latestFootprints: CoalitionFootprints? { state.withLock { $0.footprints } }

    /// 能耗、perflevel0 等辅助槽是否可信（自检 S4）。
    public var auxiliarySlotsTrusted: Bool { state.withLock { $0.slotsTrusted } }

    /// 打开后每个窗口都留存下来，由历史记录用 `drainRetainedWindows()` 取走（CPU 模块设计 §6 的每应用分钟数据）。
    /// Top N 只看 `latestWindow`；面板和历史共用同一次扫描时，有效间隔取两者较短的那个，
    /// 只读 `latestWindow` 会漏掉中间的窗口，所以历史要逐个取。关闭时清空。
    public func setRetainsWindows(_ retains: Bool) {
        state.withLock {
            $0.retainsWindows = retains
            if !retains { $0.retained = [] }
        }
    }

    /// 取走留存的窗口（按时间先后）。
    public func drainRetainedWindows() -> [AppActivityWindow] {
        state.withLock {
            let out = $0.retained
            $0.retained = []
            return out
        }
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let symbols = CoalitionReader.isAvailable
        checks.append(SelfTestCheck(name: "app.coalition.symbols", passed: symbols, detail: symbols ? "resolved" : "dlsym failed"))
        guard symbols, let entries = CoalitionReader.list() else {
            if symbols { checks.append(SelfTestCheck(name: "app.coalition.list", passed: false, detail: "proc_listcoalitions failed")) }
            return finish(checks, slotsTrusted: false)
        }
        let mine = CoalitionReader.coalition(ofPID: getpid())
        let listed = mine.map { id in entries.contains { $0.id == id } } ?? false
        let members = mine.flatMap { CoalitionReader.members(of: $0, tasksHint: 8) } ?? []
        checks.append(
            SelfTestCheck(
                name: "app.coalition.self", passed: listed && members.contains(getpid()),
                detail: "\(entries.count) coalitions; own coalition listed \(listed), \(members.count) members"))
        let probe = mine.flatMap(CoalitionReader.probeUsage(of:))
        let layoutOK = probe.map { $0.bytesWritten >= CoalitionUsage.minimumBytes && $0.usage.eqosLength == CoalitionUsage.expectedEQoSLength } ?? false
        checks.append(
            SelfTestCheck(
                name: "app.coalition.layout", passed: layoutOK,
                detail: probe.map { "\($0.bytesWritten) bytes, slot23=\($0.usage.eqosLength)" } ?? "probe failed"))
        guard listed, layoutOK else { return finish(checks, slotsTrusted: false) }

        let s4 = Self.slotCrossCheck(entries)
        checks.append(SelfTestCheck(name: "app.coalition.slots", passed: s4.passed, detail: s4.detail, severity: .advisory))
        if members.count == 1, let mine {
            checks.append(Self.spinCheck(coalition: mine))
        } else {
            checks.append(
                SelfTestCheck(
                    name: "app.coalition.spin", passed: true,
                    detail: "skipped: own coalition has \(members.count) members", severity: .advisory))
        }
        return finish(checks, slotsTrusted: s4.passed)
    }

    private func finish(_ checks: [SelfTestCheck], slotsTrusted: Bool) -> SelfTestResult {
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            if $0.usable == false, result.isUsable { $0.previous = [:]; $0.previousMaxID = nil; $0.previousTime = nil }
            $0.usable = result.isUsable
            $0.warnings = !result.warnings.isEmpty
            $0.slotsTrusted = slotsTrusted
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        guard state.withLock({ $0.usable }) != false else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        guard let entries = CoalitionReader.list(), let timebase = MachTimebase.current else {
            return CollectorOutput(
                samples: [.unavailable(.appCoalitionCPU, reason: .readFailed("proc_listcoalitions"), at: time)],
                status: .unavailable, dataPath: Self.dataPath)
        }
        var current: [UInt64: CoalitionUsage] = [:]
        current.reserveCapacity(entries.count)
        var tasks: [UInt64: UInt32] = [:]
        let maxID = entries.map(\.id).max()
        for entry in entries where entry.tasks > 0 {
            guard let usage = CoalitionReader.usage(of: entry.id) else { continue }
            current[entry.id] = usage
            tasks[entry.id] = entry.tasks
        }
        let footprints = CoalitionFootprints(
            time: time,
            coalitions: current.map { CoalitionFootprint(id: $0.key, tasks: tasks[$0.key] ?? 0, bytes: $0.value.physFootprint) }
                .sorted { $0.bytes > $1.bytes })
        return state.withLock { s in
            let previousMaxID = s.previousMaxID
            s.footprints = footprints
            defer {
                s.previous = current
                s.previousMaxID = maxID
                s.previousTime = time
            }
            guard let previousTime = s.previousTime, time.monotonicNanos > previousTime.monotonicNanos,
                let previousMaxID
            else {
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 建立基线
            }
            let elapsed = time.monotonicNanos - previousTime.monotonicNanos
            var deltas = Self.deltas(
                previous: s.previous, current: current, tasks: tasks, previousMaxID: previousMaxID, timebase: timebase)
            deltas.sort { $0.cpuNanos > $1.cpuNanos }
            let window = AppActivityWindow(
                time: time, elapsedNanos: elapsed, coalitions: deltas, slotsTrusted: s.slotsTrusted)
            s.latest = window
            if s.retainsWindows {
                s.retained.append(window)
                if s.retained.count > Self.retainedWindowLimit { s.retained.removeFirst(s.retained.count - Self.retainedWindowLimit) }
            }
            var samples = Self.summarySamples(window, slotsTrusted: s.slotsTrusted, at: time)
            samples.append(aneSample(window, at: time))
            return CollectorOutput(samples: samples, status: s.warnings ? .degraded : .ok, dataPath: Self.dataPath)
        }
    }

    /// ANE 功率（估算，D58）：全部 coalition 槽位 39 的差分合计 ÷ 窗口长度。同时记进账本，供 PMGR 批次对账；
    /// 对账连续失败时显示不可用。不看 S4（S4 核对的是 CPU 能耗等槽位，进程在读取间隙里跑动时会偶发不过），
    /// 槽位 39 的可信度由 PMGR 批次对账判断。
    private func aneSample(_ window: AppActivityWindow, at time: SampleTime) -> Sample {
        let seconds = Double(window.elapsedNanos) / 1e9
        let joules = Double(window.totalANEEnergyNanojoules) / 1e9
        ledger?.recordANE(joules: joules, seconds: seconds, at: time.wallClock)
        if ledger?.isDisabled(.ane) == true {
            return .unavailable(.anePowerEstimated, reason: .selfTestFailed("cross-check"), at: time)
        }
        return Sample(id: .anePowerEstimated, value: joules / seconds, quality: .estimated, time: time)
    }

    public func resetBaseline() {
        state.withLock {
            $0.previous = [:]
            $0.previousMaxID = nil
            $0.previousTime = nil
        }
    }

    /// 两次扫描之间每个 coalition 的增量（纯函数，便于单测）。
    static func deltas(
        previous: [UInt64: CoalitionUsage], current: [UInt64: CoalitionUsage], tasks: [UInt64: UInt32],
        previousMaxID: UInt64, timebase: MachTimebase
    ) -> [CoalitionDelta] {
        var deltas: [CoalitionDelta] = []
        deltas.reserveCapacity(current.count)
        for (id, now) in current {
            let before = previous[id]
            // 重新有了成员的旧 coalition：累计值含开机以来的用量，这一轮只建基线（见文件头）。
            if before == nil, id <= previousMaxID { continue }
            // 计数器回退（不应发生；cid 被复用时可能）：按复位处理，丢弃这一段。
            if let before, now.cpuTicks < before.cpuTicks { continue }
            func d(_ a: UInt64, _ b: UInt64?) -> UInt64 { a >= (b ?? 0) ? a - (b ?? 0) : 0 }
            deltas.append(
                CoalitionDelta(
                    id: id, tasks: tasks[id] ?? 0,
                    cpuNanos: timebase.nanoseconds(fromTicks: d(now.cpuTicks, before?.cpuTicks)),
                    perfLevel0Nanos: timebase.nanoseconds(fromTicks: d(now.perfLevel0Ticks, before?.perfLevel0Ticks)),
                    cycles: d(now.cycles, before?.cycles), perfLevel0Cycles: d(now.perfLevel0Cycles, before?.perfLevel0Cycles),
                    energyNanojoules: d(now.energyNanojoules, before?.energyNanojoules),
                    diskReadBytes: d(now.diskBytesRead, before?.diskBytesRead),
                    diskWrittenBytes: d(now.diskBytesWritten, before?.diskBytesWritten),
                    gpuNanos: d(now.gpuNanos, before?.gpuNanos),
                    gpuEnergyNanojoules: d(now.gpuEnergyNanojoules, before?.gpuEnergyNanojoules),
                    aneNanos: timebase.nanoseconds(fromTicks: d(now.aneTicks, before?.aneTicks)),
                    aneEnergyNanojoules: d(now.aneEnergyNanojoules, before?.aneEnergyNanojoules),
                    wakeups: d(now.wakeups, before?.wakeups), pageins: d(now.pageins, before?.pageins),
                    footprintBytes: now.physFootprint, cpuTotalNanos: timebase.nanoseconds(fromTicks: now.cpuTicks),
                    membershipChanged: before.map {
                        $0.tasksStarted != now.tasksStarted || $0.tasksExited != now.tasksExited
                    } ?? true,
                    isNew: before == nil))
        }
        return deltas
    }

    // MARK: - 汇总

    /// 整机汇总：全体进程的 CPU（按单核比例）、perflevel0 时间占比、perflevel0 与其余档的平均频率。
    static func summarySamples(_ window: AppActivityWindow, slotsTrusted: Bool, at time: SampleTime) -> [Sample] {
        let elapsed = Double(window.elapsedNanos)
        let cpu = Double(window.totalCPUNanos)
        var samples = [Sample(id: .appCoalitionCPU, value: cpu / elapsed, time: time)]
        guard slotsTrusted else {
            let reason = UnavailableReason.selfTestFailed("auxiliary slots not trusted")
            return samples + [
                .unavailable(.appCoalitionPerfLevel0Share, reason: reason, at: time),
                .unavailable(.appCoalitionPerfLevel0Frequency, reason: reason, at: time),
                .unavailable(.appCoalitionOtherLevelFrequency, reason: reason, at: time),
            ]
        }
        let p0 = window.coalitions.reduce(0.0) { $0 + Double($1.perfLevel0Nanos) }
        let cycles = window.coalitions.reduce(0.0) { $0 + Double($1.cycles) }
        let p0Cycles = window.coalitions.reduce(0.0) { $0 + Double($1.perfLevel0Cycles) }
        func ratio(_ id: MetricID, _ a: Double, _ b: Double, scale: Double = 1) -> Sample {
            b > 0 ? Sample(id: id, value: a / b * scale, time: time) : .unavailable(id, reason: .noElapsedTicks(), at: time)
        }
        samples.append(ratio(.appCoalitionPerfLevel0Share, p0, cpu))
        samples.append(ratio(.appCoalitionPerfLevel0Frequency, p0Cycles, p0, scale: 1e9))
        samples.append(ratio(.appCoalitionOtherLevelFrequency, cycles - p0Cycles, cpu - p0, scale: 1e9))
        return samples
    }

    // MARK: - 自检

    /// S4：同 uid 单成员 coalition 上，槽位与成员 rusage_info_v6 逐位相等的比例。
    static func slotCrossCheck(_ entries: [CoalitionEntry]) -> (passed: Bool, detail: String) {
        let uid = getuid()
        var used = 0
        var footprint = 0
        var energy = 0
        var ptime = 0
        for entry in entries where entry.tasks == 1 {
            guard used < 60, let pids = CoalitionReader.members(of: entry.id, tasksHint: 1), pids.count == 1,
                ProcessInfoReader.uid(of: pids[0]) == uid, let usage = CoalitionReader.usage(of: entry.id),
                let r = ProcessInfoReader.rusage(of: pids[0])
            else { continue }
            used += 1
            if usage.physFootprint == r.ri_phys_footprint { footprint += 1 }
            if usage.energyNanojoules == r.ri_energy_nj { energy += 1 }
            if usage.perfLevel0Ticks == r.ri_user_ptime + r.ri_system_ptime { ptime += 1 }
        }
        guard used >= 5 else { return (true, "inconclusive: \(used) same-uid single-member coalitions") }
        let ok = [footprint, energy, ptime].allSatisfy { Double($0) >= 0.9 * Double(used) }
        return (ok, "of \(used): footprint \(footprint), energy \(energy), ptime \(ptime) exact")
    }

    /// S5：本线程自旋 60 ms，本 coalition 的 CPU 增量与本进程 rusage 增量一致。
    static func spinCheck(coalition: UInt64) -> SelfTestCheck {
        guard let a0 = CoalitionReader.usage(of: coalition), let r0 = ProcessInfoReader.rusage(of: getpid()) else {
            return SelfTestCheck(name: "app.coalition.spin", passed: false, detail: "read failed", severity: .advisory)
        }
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 60_000_000
        var x: UInt64 = 1
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { x = x &* 6_364_136_223_846_793_005 &+ 1 }
        guard let a1 = CoalitionReader.usage(of: coalition), let r1 = ProcessInfoReader.rusage(of: getpid()), x != 0 else {
            return SelfTestCheck(name: "app.coalition.spin", passed: false, detail: "read failed", severity: .advisory)
        }
        let slots = Double(a1.cpuTicks - a0.cpuTicks)
        let rusage = Double((r1.ri_user_time + r1.ri_system_time) - (r0.ri_user_time + r0.ri_system_time))
        let ratio = rusage > 0 ? slots / rusage : 0
        return SelfTestCheck(
            name: "app.coalition.spin", passed: (0.98...1.02).contains(ratio),
            detail: "Δslots24–30 / Δrusage = \((ratio * 1000).rounded() / 1000)", severity: .advisory)
    }
}

/// 公开的 proc_* 读取（不涉及私有符号）。
public enum ProcessInfoReader {
    public static func rusage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return rc == 0 ? info : nil
    }

    public static func uid(of pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info.pbsi_uid : nil
    }

    /// 可执行文件路径；读不到（例如 pid 0）时为 nil。
    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
