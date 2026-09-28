// 指数滑动平均（K24：菜单栏数字做 EMA 平滑，CPU τ≈1–2 s；面板图表用原始值）。

import Foundation

/// 按时间常数 τ 做指数滑动平均。采样间隔不固定时按实际时间差计算权重：`alpha = 1 − exp(−Δt/τ)`。
///
/// - 输入不可用（nil 或非有限值）时清空状态并返回 nil：不可用不能被平滑成一个「看起来正常」的数；
/// - 第一个值、或与上一个值相隔超过 `resetAfter` 秒（例如暂停采样后恢复）时直接采用新值，不和旧值混合。
public struct ExponentialSmoother: Sendable, Hashable {
    /// 时间常数，秒。
    public let timeConstant: Double
    /// 相隔超过这么多秒就不再混合旧值，秒。
    public let resetAfter: Double

    /// 当前的平滑值；还没有输入或刚被清空时为 nil。
    public private(set) var value: Double?
    private var lastNanos: UInt64?

    /// - Parameters:
    ///   - timeConstant: 时间常数 τ，秒。
    ///   - resetAfter: 默认为 10τ。
    public init(timeConstant: Double, resetAfter: Double? = nil) {
        self.timeConstant = timeConstant
        self.resetAfter = resetAfter ?? timeConstant * 10
    }

    /// 输入一个新值，返回平滑后的值。
    @discardableResult
    public mutating func update(_ input: Double?, atMonotonicNanos time: UInt64) -> Double? {
        guard let input, input.isFinite else {
            reset()
            return nil
        }
        defer { lastNanos = time }
        guard let previous = value, let lastNanos, time > lastNanos, timeConstant > 0 else {
            value = input
            return input
        }
        let dt = Double(time - lastNanos) / 1e9
        guard dt <= resetAfter else {
            value = input
            return input
        }
        let alpha = 1 - exp(-dt / timeConstant)
        let smoothed = previous + alpha * (input - previous)
        value = smoothed
        return smoothed
    }

    public mutating func reset() {
        value = nil
        lastNanos = nil
    }
}
