// 数据质量（K17，M0 设计 §4）。
//
// 「不可用」用显式状态表示，不用 0 或 NaN 代替；推断、估算、30 分钟批次类指标也要在这里标出来。

/// 一个样本的数据质量。
public enum DataQuality: Sendable, Hashable, Codable {
    /// 直接测得。
    case measured
    /// 由 PMGR 每 30 分钟批量发布的数据，不是实时值（调研报告 §2.5）。
    case batched30min
    /// 估算值：例如部分核的计数器被丢弃后，由其余核算出的总占用。
    case estimated
    /// 只能当相对量看的指标，绝对值没有物理意义。
    case relative
    /// 语义靠推断、没法自检的指标（K17 的「实验性」分组）。
    case inferred
    /// 不可用，附原因。此时样本没有数值。
    case unavailable(UnavailableReason)

    /// 是否为不可用。
    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// 不可用的原因。
///
/// `code` 是稳定的机器可读代码，由 app 映射成本地化文案（D23）；`detail` 是给诊断页看的技术细节，
/// 例如 `kr=5`，不做本地化，也不能含设备唯一标识。
public struct UnavailableReason: Sendable, Hashable, Codable, CustomStringConvertible {
    public var code: String
    public var detail: String?

    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var description: String {
        if let detail { return "\(code)(\(detail))" }
        return code
    }

    /// 读取数据源失败（系统调用返回错误）。
    public static func readFailed(_ detail: String? = nil) -> Self { Self(code: "readFailed", detail: detail) }
    /// 数据源自检未通过，按 D05 不显示可能错误的数值。
    public static func selfTestFailed(_ detail: String? = nil) -> Self { Self(code: "selfTestFailed", detail: detail) }
    /// 计数器回退，按复位处理，丢弃这一段。
    public static func counterReset(_ detail: String? = nil) -> Self { Self(code: "counterReset", detail: detail) }
    /// 两次读数之间计数器没有前进，无法算出比例。
    public static func noElapsedTicks(_ detail: String? = nil) -> Self { Self(code: "noElapsedTicks", detail: detail) }
    /// 簇几乎不活跃，频率没有意义（UI 显示「空闲」）。
    public static func clusterIdle(_ detail: String? = nil) -> Self { Self(code: "clusterIdle", detail: detail) }
    /// 本芯片没有专用功耗轨，按 D29 不估算。
    public static func noDedicatedRail(_ detail: String? = nil) -> Self { Self(code: "noDedicatedRail", detail: detail) }
    /// 传感器所在区域断电，读到的是占位值（M4 的 40.0、-4.0 等）。
    public static func sensorPowerGated(_ detail: String? = nil) -> Self { Self(code: "sensorPowerGated", detail: detail) }
    /// 温度键归簇还在学习中。
    public static func learning(_ detail: String? = nil) -> Self { Self(code: "learning", detail: detail) }
    /// 没有归到任何簇的数据。
    public static func notAttributed(_ detail: String? = nil) -> Self { Self(code: "notAttributed", detail: detail) }
}
