// 引擎对外交付的内容（M0 设计 §5.2、§6 诊断页）。

import SysModel

/// 一个已登记的需求及其当前是否生效。
public struct RegisteredDemand: Hashable, Sendable {
    /// 与 `DemandToken.id` 相同。
    public var id: UInt64
    public var demand: Demand
    /// 当前降频下是否生效（`paused` 时前台需求不生效）。
    public var isActive: Bool
    /// 生效时的有效间隔（基础 tick 数，已乘降频倍数）。
    public var effectiveInterval: Int?

    public init(id: UInt64, demand: Demand, isActive: Bool, effectiveInterval: Int?) {
        self.id = id
        self.demand = demand
        self.isActive = isActive
        self.effectiveInterval = effectiveInterval
    }
}

/// 调度器状态，供诊断页显示（K19）。
public struct EngineStatus: Hashable, Sendable {
    /// 至今执行过的 tick 数（每次唤醒并采样算一次）。
    public var tickCount: UInt64
    /// 最近一次执行的 tick 序号（即 Unix 秒数）。
    public var lastTick: Int64?
    /// 已排定的下一次唤醒的 tick 序号；nil 表示定时器已停，不会再唤醒。
    public var nextTick: Int64?
    public var demands: [RegisteredDemand]
    /// 每个有需求的采集器的有效间隔（基础 tick 数）。
    public var effectiveIntervals: [CollectorID: Int]
    public var throttle: ThrottleFactor
    public var throttleReasons: Set<ThrottleReason>
    /// 所有注册采集器的健康信息，按 ID 排序。
    public var health: [CollectorHealth]

    public init(
        tickCount: UInt64, lastTick: Int64?, nextTick: Int64?, demands: [RegisteredDemand],
        effectiveIntervals: [CollectorID: Int], throttle: ThrottleFactor, throttleReasons: Set<ThrottleReason>,
        health: [CollectorHealth]
    ) {
        self.tickCount = tickCount
        self.lastTick = lastTick
        self.nextTick = nextTick
        self.demands = demands
        self.effectiveIntervals = effectiveIntervals
        self.throttle = throttle
        self.throttleReasons = throttleReasons
        self.health = health
    }

    /// 定时器是否处于排定状态。
    public var isTimerArmed: Bool { nextTick != nil }
}

/// 一个 tick 的全部结果，只交付一次（M0 设计 §5.2）。
public struct TickResult: Hashable, Sendable {
    /// tick 序号（即 Unix 秒数）。
    public var tick: Int64
    /// 本 tick 所有样本共用的采样时刻。
    public var time: SampleTime
    /// 本 tick 跑过的采集器，按执行顺序。
    public var collectors: [CollectorID]
    /// 本 tick 产生的全部样本。刚建立基线的采集器可能不出样本。
    public var samples: [Sample]
    /// 整个 tick 的耗时（所有采集器加上引擎自身的簿记）。各采集器的耗时见 `status.health`。
    public var cost: SampleCost
    /// tick 结束时的调度器状态。
    public var status: EngineStatus
    /// 本结果来自哪条通道：主 tick 的结果为 `.inline`；阻塞通道的每个采集器各交付一个 `.blocking` 结果，
    /// tick 序号和 `time` 与同一个 tick 的主结果相同。
    public var lane: CollectorLane

    public init(
        tick: Int64, time: SampleTime, collectors: [CollectorID], samples: [Sample], cost: SampleCost,
        status: EngineStatus, lane: CollectorLane = .inline
    ) {
        self.tick = tick
        self.time = time
        self.collectors = collectors
        self.samples = samples
        self.cost = cost
        self.status = status
        self.lane = lane
    }
}

/// 订阅者收到的事件。
public enum EngineEvent: Hashable, Sendable {
    /// 一个 tick 的结果。
    case tick(TickResult)
    /// 需求、降频或自检结果变化后的状态（没有 tick 时诊断页也能看到变化）。订阅时先收到一次当前状态。
    case status(EngineStatus)
}
