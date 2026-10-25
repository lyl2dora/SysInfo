// 样本与采样时间（K17，M0 设计 §4）。

import Darwin
import Foundation

/// 采样时刻：两个单调时钟加一个墙钟。
/// - `monotonicNanos`（不含睡眠）用于差分算速率：系统睡眠期间进程不跑、计数器也不走；
/// - `continuousNanos`（含睡眠）用于「距今多久」：环形缓冲的保留期、图表的时间轴、均值窗口、
///   EMA 的「间隔过长就重置」。用不含睡眠的时钟做这些，睡眠前的数据醒来后会被当成「刚才」；
/// - `wallClock` 用于历史记录和显示时刻。
public struct SampleTime: Sendable, Hashable, Codable {
    /// 单调时钟，纳秒，来自 `CLOCK_UPTIME_RAW`（不含系统睡眠时间，不受改时间影响）。
    public var monotonicNanos: UInt64
    /// 连续时钟，纳秒，来自 `CLOCK_MONOTONIC_RAW`（即 `mach_continuous_time`：包含系统睡眠时间，不受改时间影响）。
    public var continuousNanos: UInt64
    /// 墙钟时间（`Date` 本身就是与时区无关的绝对时刻）。
    public var wallClock: Date

    /// `continuousNanos` 省略时取 `monotonicNanos`（测试，或明确两者之间没有经过睡眠的场合）。
    public init(monotonicNanos: UInt64, continuousNanos: UInt64? = nil, wallClock: Date) {
        self.monotonicNanos = monotonicNanos
        self.continuousNanos = continuousNanos ?? monotonicNanos
        self.wallClock = wallClock
    }

    /// 当前时刻。
    public static func now() -> SampleTime {
        SampleTime(
            monotonicNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            continuousNanos: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
            wallClock: Date())
    }

    private enum CodingKeys: String, CodingKey {
        case monotonicNanos, continuousNanos, wallClock
    }

    /// 没有 `continuousNanos` 字段的旧数据按 `monotonicNanos` 解码。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let monotonic = try c.decode(UInt64.self, forKey: .monotonicNanos)
        self.init(
            monotonicNanos: monotonic,
            continuousNanos: try c.decodeIfPresent(UInt64.self, forKey: .continuousNanos),
            wallClock: try c.decode(Date.self, forKey: .wallClock))
    }
}

/// 一个指标在某一时刻的取值。
///
/// 数值一律是 SI 基本单位的 `Double`，占用率用 0…1 的比例（K17、K24）。
/// 不变式：`value == nil` 当且仅当 `quality` 为 `.unavailable`。
public struct Sample: Sendable, Hashable, Codable {
    public let id: MetricID
    public let value: Double?
    public let quality: DataQuality
    public let time: SampleTime

    /// 有数值的样本。`quality` 不能是 `.unavailable`，不可用请用 `Sample.unavailable(_:reason:at:)`。
    /// 数值不是有限数（除零得出的 inf / NaN）时按不可用处理，不让 NaN 冒充读数（K17）。
    public init(id: MetricID, value: Double, quality: DataQuality = .measured, time: SampleTime) {
        precondition(!quality.isUnavailable, "有数值的样本不能标为不可用；请用 Sample.unavailable")
        self.id = id
        self.time = time
        if value.isFinite {
            self.value = value
            self.quality = quality
        } else {
            self.value = nil
            self.quality = .unavailable(.nonFinite())
        }
    }

    /// 不可用的样本：没有数值，只有原因。
    public static func unavailable(_ id: MetricID, reason: UnavailableReason, at time: SampleTime) -> Sample {
        Sample(uncheckedID: id, value: nil, quality: .unavailable(reason), time: time)
    }

    private init(uncheckedID id: MetricID, value: Double?, quality: DataQuality, time: SampleTime) {
        self.id = id
        self.value = value
        self.quality = quality
        self.time = time
    }

    private enum CodingKeys: String, CodingKey {
        case id, value, quality, time
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(MetricID.self, forKey: .id)
        let value = try c.decodeIfPresent(Double.self, forKey: .value)
        let quality = try c.decode(DataQuality.self, forKey: .quality)
        let time = try c.decode(SampleTime.self, forKey: .time)
        guard (value == nil) == quality.isUnavailable else {
            throw DecodingError.dataCorruptedError(
                forKey: .value, in: c,
                debugDescription: "value 与 quality 不一致：不可用的样本不能有数值，可用的样本必须有数值")
        }
        self.init(uncheckedID: id, value: value, quality: quality, time: time)
    }
}
