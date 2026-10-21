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
    /// 盘温：跟随菜单栏盘温 widget 绑定的盘（含「所有盘最高温」），盘名见 `diskName`。
    case diskTemperature
    // v3（docs/design/widgets-rich.md §3）
    case gpuUsage
    /// GPU 功率（AGX，D44）。
    case gpuPower
    /// 内存已用与总量，字节。
    case memoryUsed
    case memoryTotal
    /// 内存压力，比例。
    case memoryPressure
    /// 交换已用，字节。
    case swapUsed
    /// 所有风扇的最高转速，rpm；没有风扇的机器不写这一项。
    case fanSpeed
    /// 容量组的可用与总量，字节：跟随菜单栏可用空间 widget 绑定的组，组名见 `diskGroupName`。
    case diskFree
    case diskTotal

    /// 带 24 h 曲线的槽位。
    public static let curved: [WidgetSlot] = [.cpuUsage, .gpuUsage, .memoryUsage, .systemPower, .socHotspot]
}

/// 写给桌面小组件的快照（v3）。
public struct WidgetSnapshot: Sendable, Hashable, Codable {
    /// 快照格式版本；字段有不兼容变化时递增。v1 只定义过类型，从没写出过。
    public static let currentVersion = 3
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

    /// CPU 的一档（`hw.perflevelN`，D20）：档数与档名运行时发现。
    public struct CPULevel: Sendable, Hashable, Codable {
        /// 本地化后的档名（主 app 写，扩展直接显示）。
        public var label: String
        /// `hw.perflevelN.name` 原文，扩展据此取颜色（D29）。
        public var name: String
        public var value: Double?
        public var quality: DataQuality

        public init(label: String, name: String, value: Double?, quality: DataQuality) {
            self.label = label
            self.name = name
            self.value = quality.isAvailable ? value : nil
            self.quality = value == nil && quality.isAvailable ? .unavailable(.readFailed("missing")) : quality
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
    /// CPU 各档占用，按档序号排列；拓扑不成立时为空。
    public var cpuLevels: [CPULevel]
    /// 盘温来自哪块盘的显示名（型号，RAID 成员为「成员 n · 型号」）；不放盘的键与序列号（D22）。
    public var diskName: String?
    /// 可用空间所属容量组的名称（卷名或 RAID 组名）。
    public var diskGroupName: String?

    public init(
        generatedAt: Date, appRunning: Bool = true, refreshInterval: TimeInterval, items: [Item],
        cpuLevels: [CPULevel] = [], diskName: String? = nil, diskGroupName: String? = nil,
        version: Int = WidgetSnapshot.currentVersion
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.appRunning = appRunning
        self.refreshInterval = refreshInterval
        self.items = items
        self.cpuLevels = cpuLevels
        self.diskName = diskName
        self.diskGroupName = diskGroupName
    }

    public func item(_ slot: WidgetSlot) -> Item? { items.first { $0.slot == slot } }

    /// 这一项的数值（不可用或没写时为 nil）。
    public func value(_ slot: WidgetSlot) -> Double? { item(slot)?.value }

    /// 容量组已用比例（可用与总量都有时）。
    public var diskUsedRatio: Double? {
        guard let free = value(.diskFree), let total = value(.diskTotal), total > 0 else { return nil }
        return min(max(1 - free / total, 0), 1)
    }

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
        case .cpuUsage, .memoryUsage, .gpuUsage, .memoryPressure: return PercentFormat.string(fromRatio: value)
        case .systemPower, .gpuPower: return String(format: value < 10 ? "%.1f W" : "%.0f W", value)
        case .socHotspot, .diskTemperature: return String(format: "%.0f°", value)
        case .networkIn, .networkOut: return bytesPerSecond(value)
        case .memoryUsed, .memoryTotal, .swapUsed: return gigabytes(value)
        case .diskFree, .diskTotal: return decimalBytes(value)
        case .fanSpeed: return String(format: "%.0f rpm", value)
        }
    }

    /// 内存类：按 1024 换算的 GB（与「活动监视器」一致），<10 一位小数。
    public static func gigabytes(_ value: Double) -> String {
        let gb = max(value, 0) / 1_073_741_824
        return String(format: gb < 9.95 ? "%.1f GB" : "%.0f GB", gb)
    }

    /// 磁盘类：按 1000 换算（K24，与访达一致），位数与菜单栏「可用空间」相同。
    public static func decimalBytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(value, 0)
        var unit = 0
        while v >= 999.5, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        let format = unit == 0 || v >= 99.5 ? "%.0f %@" : v >= 9.95 ? "%.1f %@" : "%.2f %@"
        return String(format: format, v, units[unit])
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
