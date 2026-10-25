// 采样引擎（M0 设计 §5.2，K18、D19、D25）。
//
// - 所有采集器共用一个合并 tick，只在有消费者（需求）时采样；没有需求时取消定时源，不再唤醒。
// - actor 的执行器就是私有串行队列，DispatchSourceTimer 也挂在这个队列上：定时器回调直接在 actor 的
//   隔离域里同步跑完整个 tick，不经 Task 跳转，也不会落到 MainActor 上（D03、D23）。
// - 定时器是一次性的，每个 tick 结束后按「下一个有采集器到期的 tick」重新排定（见 Schedule）。
//   tick 网格对齐到整秒之后约 50 ms，leeway 约 100 ms，让系统合并唤醒。
// - 阻塞通道（CPU 模块设计 §5.1）：`.blocking` 采集器在第二条串行队列上执行，和主 tick 并行，
//   完成后回到 actor 的队列更新健康信息，并以同一个 tick 序号单独交付一个结果；
//   上一次还没结束时本 tick 跳过它（计入 skippedBusyCount）。到期计算、降频、暂停的语义不变，仍只有一个 tick 网格。

import Darwin
import Dispatch
import Foundation
import SysModel
import os

public actor SamplingEngine {
    public struct Configuration: Hashable, Sendable {
        /// tick 相对整秒的偏移，纳秒。
        public var alignmentOffsetNanos: Int64
        /// 定时器 leeway，纳秒。
        public var leewayNanos: Int
        /// 采集器连续这么多次输出 `unavailable` 后重新自检（K19「运行中连续越界」）。
        /// 复检后仍不可用时，下一次复检的门槛翻倍（最多 64 倍），避免长期故障时反复自检、刷日志。
        public var recheckAfterConsecutiveUnavailable: Int
        /// 每个订阅者最多缓存的事件数；订阅者跟不上时丢弃最旧的。
        public var eventBufferSize: Int

        public init(
            alignmentOffsetNanos: Int64 = 50_000_000,
            leewayNanos: Int = 100_000_000,
            recheckAfterConsecutiveUnavailable: Int = 10,
            eventBufferSize: Int = 16
        ) {
            self.alignmentOffsetNanos = alignmentOffsetNanos
            self.leewayNanos = leewayNanos
            self.recheckAfterConsecutiveUnavailable = recheckAfterConsecutiveUnavailable
            self.eventBufferSize = eventBufferSize
        }
    }

    // MARK: - 执行器

    private nonisolated let queue: DispatchSerialQueue
    /// 阻塞通道的串行队列。
    private nonisolated let blockingQueue: DispatchQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    // MARK: - 状态

    /// 注册的全部采集器 ID，按 ID 排序。
    public nonisolated let collectorIDs: [CollectorID]
    /// 自检顺序：按登记顺序。有依赖关系时由调用方安排（`cpu.load` 的自检会刷新拓扑，排在按拓扑建方案的采集器前面）。
    private let selfTestOrder: [CollectorID]

    private let configuration: Configuration
    private let grid: TickGrid
    private let collectors: [CollectorID: any Collector]
    private var health: [CollectorID: HealthRecord]

    private var demands: [UInt64: Demand] = [:]
    private var nextDemandID: UInt64 = 1
    private var throttle: ThrottleFactor = .normal
    private var throttleReasons: Set<ThrottleReason> = []
    /// 当前每个有需求的采集器的有效间隔。
    private var intervals: [CollectorID: Int] = [:]
    /// 刚获得需求、还没建立差分基线的采集器。
    private var pendingBaseline: Set<CollectorID> = []
    /// 正在阻塞通道上采样的采集器。
    private var blockingInFlight: Set<CollectorID> = []

    private var timer: (any DispatchSourceTimer)?
    private var scheduledTick: Int64?
    /// 已排定唤醒的截止时刻（与定时器同一时钟）。用来识别改排之前就已进入队列的旧事件。
    private var scheduledDeadline: DispatchTime?
    private var lastRunTick: Int64?
    private var tickCount: UInt64 = 0

    private var subscribers: [UInt64: AsyncStream<EngineEvent>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sysinfo-cli", category: "engine")

    /// - Parameter collectors: 采集器的 ID 必须互不相同。实例从此归引擎所有，调用方不应再直接调用它们。
    public init(collectors: [any Collector], configuration: Configuration = Configuration()) {
        var byID: [CollectorID: any Collector] = [:]
        for collector in collectors {
            precondition(byID[collector.id] == nil, "重复的采集器 ID：\(collector.id)")
            byID[collector.id] = collector
        }
        self.collectors = byID
        self.collectorIDs = byID.keys.sorted()
        self.selfTestOrder = collectors.map(\.id)
        self.health = byID.mapValues { HealthRecord(id: $0.id) }
        self.configuration = configuration
        self.grid = TickGrid(offsetNanos: configuration.alignmentOffsetNanos)
        self.queue = DispatchSerialQueue(label: "zone.lyl.sysinfo.sampling", qos: .utility)
        self.blockingQueue = DispatchQueue(label: "zone.lyl.sysinfo.sampling.blocking", qos: .utility)
    }

    deinit {
        timer?.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    // MARK: - 需求

    /// 登记一个需求。返回的 token 释放或 `cancel()` 即注销。
    public func addDemand(_ demand: Demand) -> DemandToken {
        let id = nextDemandID
        nextDemandID += 1
        demands[id] = demand
        logger.debug(
            "登记需求 #\(id) \(demand.source.rawValue, privacy: .public)：\(demand.collectors.map(\.rawValue).sorted(), privacy: .public) 每 \(demand.interval) tick"
        )
        recompute()
        return DemandToken(id: id, engine: self)
    }

    /// 注销需求并立即生效（与 `token.cancel()` 不同，返回时定时器状态已经更新）。
    public func remove(_ token: DemandToken) {
        _ = token.markCancelled()
        removeDemand(id: token.id)
    }

    func removeDemand(id: UInt64) {
        guard let demand = demands.removeValue(forKey: id) else { return }
        logger.debug("注销需求 #\(id) \(demand.source.rawValue, privacy: .public)")
        recompute()
    }

    // MARK: - 降频

    /// 设置降频（M0 设计 §5.2）。信号汇总在 app 层完成。
    public func setThrottle(factor: ThrottleFactor, reasons: Set<ThrottleReason>) {
        guard factor != throttle || reasons != throttleReasons else { return }
        throttle = factor
        throttleReasons = reasons
        logger.info(
            "降频变为 \(String(describing: factor), privacy: .public)，原因：\(reasons.sorted().map(\.rawValue), privacy: .public)"
        )
        recompute()
    }

    // MARK: - 自检

    /// 对所有采集器重新自检（启动、唤醒、系统 build 号变化时由 app 调用，K19）。
    @discardableResult
    public func runSelfTests() -> [CollectorID: SelfTestResult] {
        var results: [CollectorID: SelfTestResult] = [:]
        for id in selfTestOrder {
            results[id] = runSelfTest(id)
        }
        broadcast(.status(status))
        return results
    }

    @discardableResult
    private func runSelfTest(_ id: CollectorID) -> SelfTestResult? {
        guard let collector = collectors[id] else { return nil }
        let result = collector.selfTest()
        health[id]?.applySelfTest(result)
        let failed = result.checks.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }
        if result.passed {
            logger.info("自检通过：\(id.rawValue, privacy: .public)")
        } else if result.isUsable {
            logger.notice("自检有提示项未通过（数据源照常使用，状态降级）：\(id.rawValue, privacy: .public) \(failed, privacy: .public)")
        } else {
            logger.error("自检未通过：\(id.rawValue, privacy: .public) \(failed, privacy: .public)")
        }
        return result
    }

    // MARK: - 订阅

    /// 订阅引擎事件。先收到一次当前状态，之后每个 tick 一个 `.tick`，需求、降频、自检变化时一个 `.status`。
    /// 订阅者跟不上时只保留最新的若干个事件。
    public func events() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: EngineEvent.self, bufferingPolicy: .bufferingNewest(max(configuration.eventBufferSize, 1)))
        let id = nextSubscriberID
        nextSubscriberID += 1
        continuation.onTermination = { [weak self] _ in
            self?.enqueue { $0.subscribers[id] = nil }
        }
        subscribers[id] = continuation
        continuation.yield(.status(status))
        return stream
    }

    private func broadcast(_ event: EngineEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - 状态

    public var status: EngineStatus {
        EngineStatus(
            tickCount: tickCount,
            lastTick: lastRunTick,
            nextTick: scheduledTick,
            demands: demands.keys.sorted().compactMap { id in
                guard let demand = demands[id] else { return nil }
                let interval = Schedule.effectiveInterval(of: demand, under: throttle)
                return RegisteredDemand(id: id, demand: demand, isActive: interval != nil, effectiveInterval: interval)
            },
            effectiveIntervals: intervals,
            throttle: throttle,
            throttleReasons: throttleReasons,
            health: collectorIDs.compactMap { health[$0]?.health })
    }

    /// 在引擎的隔离域里异步执行（任何线程都可以调用）。
    nonisolated func enqueue(_ operation: @escaping @Sendable (isolated SamplingEngine) -> Void) {
        queue.async {
            self.assumeIsolated { operation($0) }
        }
    }

    // MARK: - 调度

    /// 需求或降频变化后：重算有效间隔，处理新获得需求的采集器，重新排定定时器。
    private func recompute() {
        let previous = Set(intervals.keys)
        intervals = Schedule.effectiveIntervals(
            for: demands.values, throttle: throttle, available: Set(collectorIDs))
        let current = Set(intervals.keys)

        for id in current.subtracting(previous).sorted() {
            activate(id)
        }
        pendingBaseline.formIntersection(current)
        rearm()
        broadcast(.status(status))
    }

    /// 采集器从「无需求」变为「有需求」：没自检过就先自检；丢弃旧基线，下一个 tick 立即建立新基线，
    /// 避免第一个样本变成整段空闲期的平均值。
    private func activate(_ id: CollectorID) {
        if health[id]?.health.selfTest == nil {
            runSelfTest(id)
        }
        collectors[id]?.resetBaseline()
        pendingBaseline.insert(id)
    }

    private func rearm() {
        let nowWall = Self.wallClockNanos()
        let start = TickGrid.searchStart(current: grid.tick(atOrBefore: nowWall), lastRun: lastRunTick)
        guard let next = Schedule.nextTick(after: start, intervals: intervals, pendingBaseline: pendingBaseline)
        else {
            if timer != nil {
                logger.debug("没有需求，定时器停止")
            }
            timer?.cancel()
            timer = nil
            scheduledTick = nil
            scheduledDeadline = nil
            return
        }
        guard next != scheduledTick else { return }

        let timer = self.timer ?? makeTimer()
        let (difference, overflow) = grid.unixNanos(of: next).subtractingReportingOverflow(nowWall)
        let delay = overflow ? Int64.max : max(difference, 0)
        let deadline = DispatchTime.now() + .nanoseconds(Int(delay))
        timer.schedule(deadline: deadline, repeating: .never, leeway: .nanoseconds(configuration.leewayNanos))
        scheduledTick = next
        scheduledDeadline = deadline
    }

    private func makeTimer() -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.timerFired() }
        }
        timer.activate()
        self.timer = timer
        logger.debug("定时器启动")
        return timer
    }

    private func timerFired() {
        // 定时器不会早于截止时刻触发。还没到截止时刻，说明这是改排之前就已进入队列的旧事件：
        // 忽略它，定时器仍按新的截止时刻排着。
        guard let tick = scheduledTick, let deadline = scheduledDeadline,
            DispatchTime.now().uptimeNanoseconds + 1_000_000 >= deadline.uptimeNanoseconds
        else { return }
        scheduledTick = nil
        scheduledDeadline = nil
        let result = runTick(tick)
        rearm()
        if var result {
            result.status = status
            broadcast(.tick(result))
        }
    }

    /// 执行一个 tick：到期的采集器各跑一次，串行执行，记录每个的墙钟与线程 CPU 耗时。
    private func runTick(_ tick: Int64) -> TickResult? {
        let due = Schedule.dueCollectors(at: tick, intervals: intervals, pendingBaseline: pendingBaseline)
        guard !due.isEmpty else { return nil }

        let tickWallStart = Clocks.uptimeNanos()
        let tickCPUStart = Clocks.threadCPUNanos()
        let time = SampleTime.now()
        var samples: [Sample] = []
        var recheck: [CollectorID] = []

        var inlineRun: [CollectorID] = []
        for id in due {
            guard let collector = collectors[id] else { continue }
            if collector.lane == .blocking {
                dispatchBlocking(collector, tick: tick, time: time)
                continue
            }
            inlineRun.append(id)
            let wallStart = Clocks.uptimeNanos()
            let cpuStart = Clocks.threadCPUNanos()
            let output = collector.sample(at: time)
            let cost = SampleCost(
                wallNanos: Clocks.uptimeNanos() &- wallStart,
                cpuNanos: Clocks.threadCPUNanos() &- cpuStart)

            samples.append(contentsOf: output.samples)
            pendingBaseline.remove(id)
            if health[id]?.apply(output, cost: cost, recheckThreshold: configuration.recheckAfterConsecutiveUnavailable)
                == true
            {
                recheck.append(id)
            }
        }
        for id in recheck {
            logger.info("\(id.rawValue, privacy: .public) 连续不可用，重新自检")
            runSelfTest(id)
        }

        tickCount += 1
        lastRunTick = tick
        let cost = SampleCost(
            wallNanos: Clocks.uptimeNanos() &- tickWallStart,
            cpuNanos: Clocks.threadCPUNanos() &- tickCPUStart)
        guard !inlineRun.isEmpty else { return nil }
        return TickResult(tick: tick, time: time, collectors: inlineRun, samples: samples, cost: cost, status: status)
    }

    /// 把一个阻塞采集器派到阻塞队列。上一次还没结束时跳过。
    private func dispatchBlocking(_ collector: any Collector, tick: Int64, time: SampleTime) {
        let id = collector.id
        guard !blockingInFlight.contains(id) else {
            health[id]?.health.skippedBusyCount += 1
            return
        }
        blockingInFlight.insert(id)
        blockingQueue.async { [weak self] in
            let wallStart = Clocks.uptimeNanos()
            let cpuStart = Clocks.threadCPUNanos()
            let output = collector.sample(at: time)
            let cost = SampleCost(
                wallNanos: Clocks.uptimeNanos() &- wallStart, cpuNanos: Clocks.threadCPUNanos() &- cpuStart)
            self?.enqueue { $0.finishBlocking(id, tick: tick, time: time, output: output, cost: cost) }
        }
    }

    private func finishBlocking(_ id: CollectorID, tick: Int64, time: SampleTime, output: CollectorOutput, cost: SampleCost) {
        blockingInFlight.remove(id)
        pendingBaseline.remove(id)
        let recheck =
            health[id]?.apply(output, cost: cost, recheckThreshold: configuration.recheckAfterConsecutiveUnavailable) == true
        if recheck {
            logger.info("\(id.rawValue, privacy: .public) 连续不可用，重新自检")
            runSelfTest(id)
        }
        broadcast(
            .tick(
                TickResult(
                    tick: tick, time: time, collectors: [id], samples: output.samples, cost: cost, status: status,
                    lane: .blocking)))
    }

    private static func wallClockNanos() -> Int64 {
        Int64(clamping: clock_gettime_nsec_np(CLOCK_REALTIME))
    }
}

/// 一个采集器的健康信息及其累计量。
struct HealthRecord: Sendable {
    var health: CollectorHealth
    var totalWallNanos: UInt64 = 0
    var totalCPUNanos: UInt64 = 0
    var consecutiveUnavailable = 0
    /// 当前的复检门槛；nil 表示用配置的初始值。
    var recheckThreshold: Int?

    /// 复检门槛最多翻到初始值的这么多倍。
    static let maxBackoffMultiplier = 64

    init(id: CollectorID) {
        health = CollectorHealth(id: id, status: .ok, dataPath: "")
    }

    mutating func applySelfTest(_ result: SelfTestResult) {
        health.selfTest = result
        if !result.isUsable { health.status = .unavailable }  // 没有需求、不再采样时也如实显示
        if health.sampleCount == 0 {
            health.dataPath = result.dataPath
        }
    }

    /// 记下一次采样；返回 true 表示连续不可用次数到了门槛，应当重新自检（计数清零，门槛翻倍）。
    /// 一旦输出不再是 `unavailable`，门槛恢复为初始值。
    mutating func apply(_ output: CollectorOutput, cost: SampleCost, recheckThreshold base: Int) -> Bool {
        health.status = output.status
        health.dataPath = output.dataPath
        health.staleCount = output.staleCount
        health.sampleCount += 1
        health.lastCost = cost
        totalWallNanos &+= cost.wallNanos
        totalCPUNanos &+= cost.cpuNanos
        health.averageCost = SampleCost(
            wallNanos: totalWallNanos / health.sampleCount,
            cpuNanos: totalCPUNanos / health.sampleCount)

        let base = max(base, 1)
        guard output.status == .unavailable else {
            consecutiveUnavailable = 0
            recheckThreshold = nil
            return false
        }
        consecutiveUnavailable += 1
        let threshold = recheckThreshold ?? base
        guard consecutiveUnavailable >= threshold else { return false }
        consecutiveUnavailable = 0
        let cap = base > Int.max / Self.maxBackoffMultiplier ? Int.max : base * Self.maxBackoffMultiplier
        recheckThreshold = threshold > cap / 2 ? cap : threshold * 2
        return true
    }
}
