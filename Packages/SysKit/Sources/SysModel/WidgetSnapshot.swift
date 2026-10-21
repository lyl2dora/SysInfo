// 桌面小组件快照（D90、D91，实现规格 docs/design/widgets.md §3）：主 app 写进组容器，小组件扩展读。
// 扩展只链接 SysModel，所以格式、陈旧判断和数值格式化都放在这里，两边共用。

import Foundation

/// 小组件上的一项。用固定的槽位而不是 MetricID：盘温的 MetricID 含盘的键，不能写进组容器（D22）。
public enum WidgetSlot: String, Sendable, Hashable, Codable, CaseIterable {
    case cpuUsage
    case memoryUsage
    case systemPower
    case socHotspot
    case networkIn
    case networkOut
    case bootDiskTemperature

    /// 带 24 h 曲线的槽位（D91：大号起 CPU 与整机功率，超大竖版再加内存与 SoC 热点）。
    public static let curved: [WidgetSlot] = [.cpuUsage, .systemPower, .memoryUsage, .socHotspot]
}

/// 写给桌面小组件的快照（v2）。
public struct WidgetSnapshot: Sendable, Hashable, Codable {
    /// 快照格式版本；字段有不兼容变化时递增。v1 只定义过类型，从没写出过。
    public static let currentVersion = 2
    /// 组容器里的文件名。
    public static let fileName = "widget-snapshot.json"
    /// 扩展发现快照缺失或陈旧时写的标记，主 app 看到后立刻补写（规格 §4.1）。
    public static let wantedMarkerName = "widget-wanted"
    /// 小组件的 kind。
    public static let widgetKind = "overview"

    /// 曲线从哪儿来（规格 §4.3）。按项各自判断：每项看自己所属模块的历史开关。
    public enum CurveSource: String, Sendable, Hashable, Codable {
        /// 历史库里最近 24 h，每 5 分钟一个点。
        case history
        /// 该模块的历史记录关着：内存里最近 15 分钟，每分钟一个点。
        case historyOff
        /// 历史开着但库里还没有这一项（刚启动）：同样是内存里最近 15 分钟。
        case recent

        /// 横轴跨度（秒）。
        public var span: TimeInterval { self == .history ? 86_400 : 900 }
    }

    public struct Item: Sendable, Hashable, Codable {
        public var slot: WidgetSlot
        /// 不可用时为 nil，原因在 `quality` 里（D24）。
        public var value: Double?
        public var quality: DataQuality
        /// 只有 `WidgetSlot.curved` 里的项才带；跨度与粒度见 `curveSource`。
        public var curve: [CurvePoint]?
        public var curveSource: CurveSource?

        public init(
            slot: WidgetSlot, value: Double?, quality: DataQuality, curve: [CurvePoint]? = nil,
            curveSource: CurveSource? = nil
        ) {
            self.slot = slot
            self.value = quality.isAvailable ? value : nil
            self.quality = value == nil && quality.isAvailable ? .unavailable(.readFailed("missing")) : quality
            self.curve = curve
            self.curveSource = curve == nil ? nil : curveSource ?? .history
        }
    }

    public struct CurvePoint: Sendable, Hashable, Codable {
        /// UTC Unix 分钟。
        public var minute: Int64
        public var value: Double

        public init(minute: Int64, value: Double) {
            self.minute = minute
            self.value = value
        }
    }

    public var version: Int
    public var generatedAt: Date
    /// 写入方是否在运行；主 app 正常退出时写一份 false（规格 §6.4）。
    public var appRunning: Bool
    /// 主 app 当前的写入节奏（秒），扩展据此判断陈旧。
    public var refreshInterval: TimeInterval
    public var items: [Item]

    public init(
        generatedAt: Date, appRunning: Bool = true, refreshInterval: TimeInterval, items: [Item],
        version: Int = WidgetSnapshot.currentVersion
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.appRunning = appRunning
        self.refreshInterval = refreshInterval
        self.items = items
    }

    public func item(_ slot: WidgetSlot) -> Item? { items.first { $0.slot == slot } }

    /// 陈旧：主 app 已退出，或者超过三个写入周期没有新快照（规格 §6.3）。
    public func isStale(at now: Date) -> Bool {
        !appRunning || now.timeIntervalSince(generatedAt) > refreshInterval * 3
    }

    /// 比一个写入周期（加 60 s 余量）还旧：扩展该留「想要数据」标记，让主 app 立刻补写。
    /// 比陈旧判断早得多：快照可能是还没放组件时写的（例如图库预览），新放上的组件不该等到下一次放置检查。
    public func wantsRefresh(at now: Date) -> Bool {
        !appRunning || now.timeIntervalSince(generatedAt) > refreshInterval + 60
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// 解码；版本不对时返回 nil（扩展当作「没有快照」处理）。
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data), snapshot.version == currentVersion else {
            return nil
        }
        return snapshot
    }
}

extension DataQuality {
    /// 有数值（除「不可用」以外的质量）。
    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// 把曲线降采样到每 `bucketMinutes` 一个点（取桶内均值），并只保留 `since` 之后的点。
public enum WidgetCurve {
    public static func bucketed(_ points: [(minute: Int64, value: Double)], bucketMinutes: Int64, since: Int64)
        -> [WidgetSnapshot.CurvePoint]
    {
        guard bucketMinutes > 0 else { return [] }
        var sums: [Int64: (Double, Int)] = [:]
        for p in points where p.minute >= since && p.value.isFinite {
            let bucket = p.minute - ((p.minute % bucketMinutes) + bucketMinutes) % bucketMinutes
            let (s, n) = sums[bucket] ?? (0, 0)
            sums[bucket] = (s + p.value, n + 1)
        }
        return sums.keys.sorted().map { WidgetSnapshot.CurvePoint(minute: $0, value: sums[$0]!.0 / Double(sums[$0]!.1)) }
    }
}

/// 小组件上的数值格式（与菜单栏一致：百分比用 `PercentFormat`，功率 <10 W 一位小数，温度取整，网速按 1000 换算）。
public enum WidgetFormat {
    public static func string(_ slot: WidgetSlot, _ value: Double?) -> String {
        guard let value, value.isFinite else { return PercentFormat.placeholder }
        switch slot {
        case .cpuUsage, .memoryUsage: return PercentFormat.string(fromRatio: value)
        case .systemPower: return String(format: value < 10 ? "%.1f W" : "%.0f W", value)
        case .socHotspot, .bootDiskTemperature: return String(format: "%.0f°", value)
        case .networkIn, .networkOut: return bytesPerSecond(value)
        }
    }

    /// 「12 KB/s」「1.2 MB/s」：<10 一位小数，否则取整。
    public static func bytesPerSecond(_ value: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = max(value, 0)
        var unit = 0
        while v >= 999.5, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        if unit == 0 { return String(format: "%.0f %@", v, units[0]) }
        return String(format: v < 9.95 ? "%.1f %@" : "%.0f %@", v, units[unit])
    }
}
