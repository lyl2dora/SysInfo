// 小组件快照（K31、D07）：现在只定义类型、占好位置，不加 App Group entitlement，也不写出。

import Foundation

/// 写给桌面小组件的慢速摘要。
public struct WidgetSnapshot: Sendable, Hashable, Codable {
    /// 快照格式版本；字段有不兼容变化时递增。
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var samples: [Sample]

    public init(generatedAt: Date, samples: [Sample], version: Int = WidgetSnapshot.currentVersion) {
        self.version = version
        self.generatedAt = generatedAt
        self.samples = samples
    }
}

/// 快照的去处。D07 开工前只有什么都不做的默认实现。
public protocol SnapshotSink: Sendable {
    func write(_ snapshot: WidgetSnapshot)
}

extension SnapshotSink {
    /// 默认什么都不做。
    public func write(_ snapshot: WidgetSnapshot) {}
}

/// 丢弃所有快照的 sink（M0 默认）。
public struct NoopSnapshotSink: SnapshotSink {
    public init() {}
}
