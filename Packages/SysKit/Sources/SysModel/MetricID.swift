// 指标标识（K17，M0 设计 §4）。

/// 指标的稳定标识，点分命名，例如 `cpu.usage.total`、`cpu.usage.core.3`、`app.self.cpu`。
///
/// 它贯穿内存环形缓冲、将来的历史库、导出列名和小组件快照，所以一旦发布就不改名。
public struct MetricID: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: MetricID, rhs: MetricID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
