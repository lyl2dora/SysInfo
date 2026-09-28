// 采样需求（K18，M0 设计 §5.2）。
//
// 消费者（菜单栏 item、面板、诊断页、CLI…）声明自己要哪些采集器、多久一次；引擎只看需求，
// D25 的「全局默认 + 逐模块覆盖」由 app 层换算成各需求的间隔。

import Synchronization
import SysModel

/// 需求的来源标签，只用于诊断页显示和日志，例如 `menubar.cpu`、`panel`、`diagnostics`。
public struct DemandSource: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static func < (lhs: DemandSource, rhs: DemandSource) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let menubarCPU: DemandSource = "menubar.cpu"
    public static let panel: DemandSource = "panel"
    public static let diagnostics: DemandSource = "diagnostics"
    public static let cli: DemandSource = "cli"
}

/// 需求的层级：决定锁屏、显示器睡眠（`ThrottleFactor.paused`）时是否保留。
public enum DemandTier: String, Hashable, Codable, Sendable, CaseIterable {
    /// 给用户看的（菜单栏、面板）：暂停时停掉。
    case foreground
    /// 后台记录（将来的历史采样）：暂停时保留。M0 还没有这类需求。
    case background
}

/// 一个消费者的采样需求。
public struct Demand: Hashable, Codable, Sendable {
    /// 需要的采集器。引擎里没有注册的 ID 会被忽略。
    public var collectors: Set<CollectorID>
    /// 采样间隔，基础 tick（1 s）的整数倍，取值 1…`Demand.maxInterval`。
    /// 直接改这个属性不会再钳制，但引擎计算有效间隔时同样按这个范围处理。
    public var interval: Int
    public var source: DemandSource
    public var tier: DemandTier

    /// 间隔上限：86 400 个基础 tick（1 天）。再长的间隔没有意义，而且 tick 序号换算成纳秒时会溢出。
    public static let maxInterval = 86_400

    /// `interval` 小于 1 时按 1 处理，大于 `maxInterval` 时按 `maxInterval` 处理。
    public init(collectors: Set<CollectorID>, interval: Int = 1, source: DemandSource, tier: DemandTier = .foreground) {
        self.collectors = collectors
        self.interval = Self.clampInterval(interval)
        self.source = source
        self.tier = tier
    }

    /// 把间隔限制在 1…`maxInterval`。
    static func clampInterval(_ interval: Int) -> Int {
        min(max(interval, 1), maxInterval)
    }
}

/// 已登记需求的凭据。显式 `cancel()` 或释放（`deinit`）即注销，重复注销没有副作用。
///
/// `cancel()` 可以在任何线程调用，注销动作异步进入引擎的串行队列；需要确认注销已生效时，
/// 用 `await engine.remove(token)`。
public final class DemandToken: Hashable, Sendable {
    public let id: UInt64
    private let engine: SamplingEngine
    private let cancelled = Atomic<Bool>(false)

    init(id: UInt64, engine: SamplingEngine) {
        self.id = id
        self.engine = engine
    }

    deinit {
        cancel()
    }

    public var isCancelled: Bool {
        cancelled.load(ordering: .acquiring)
    }

    public func cancel() {
        guard markCancelled() else { return }
        let id = id
        engine.enqueue { $0.removeDemand(id: id) }
    }

    /// 首次标记为已注销时返回 true。
    func markCancelled() -> Bool {
        !cancelled.exchange(true, ordering: .acquiringAndReleasing)
    }

    public static func == (lhs: DemandToken, rhs: DemandToken) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
