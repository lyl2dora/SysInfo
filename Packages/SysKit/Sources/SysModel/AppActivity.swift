// 应用活动窗口的值类型（D67、D69，应用活动设计 §3）。
//
// - 「现在」档的一行来自一个 coalition 窗口：数值都是窗口内的速率，另有累计 CPU 时间与 footprint 当前值；
// - 历史时段的一行来自历史库按应用汇总：数值是时段内的总量（CPU 时间、能耗、读写字节、唤醒次数）与 footprint 峰值；
// - 两种行共用一个类型，用不到的字段为 nil，表格按时间段决定显示哪组列。

import Foundation

/// 侧栏分类（D67 AA6）。
public enum AppActivityCategory: String, Hashable, Codable, Sendable, CaseIterable {
    case all
    /// 有 .app bundle 的应用。
    case apps
    /// 没有 .app 的后台进程与系统守护进程。
    case background
    /// 当前（或时段内）持有阻止睡眠断言的应用。
    case preventingSleep
}

/// 时间段（D67 AA4）。
public enum AppActivityRange: String, Hashable, Codable, Sendable, CaseIterable {
    case now
    case hour
    case today
    case week
    case month

    /// 历史时段的起点；「现在」为 nil。「今天」按本地时区切日。
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .now: nil
        case .hour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// 一个应用在应用活动表格里的一行。
public struct AppActivityRow: Hashable, Sendable, Identifiable {
    /// 「现在」档为 `c<coalition id>`，历史时段为应用身份键。
    public var id: String
    /// 应用身份键（bundle id、可执行文件路径或 `kernel_task`，同 `AppIdentity.key`）。
    public var key: String
    public var name: String
    /// 代表成员所在 .app 的路径（取图标用）；历史时段里应用已不在原处时可能为 nil。
    public var appPath: String?
    /// 有 .app bundle（分类「App」）。
    public var isApp: Bool
    /// 「现在」档：coalition id、代表 pid、成员数。历史时段为 nil。
    public var coalitionID: UInt64?
    public var representativePID: Int32?
    public var memberCount: Int?
    /// 宿主 coalition（终端、Xcode）里占用最高的成员名（D67 默认做法）；只在「现在」档、成员多于 1 时给出。
    public var topMemberName: String?

    // MARK: 「现在」档：窗口内的速率
    /// CPU，按单核比例。
    public var cpu: Double?
    /// 开机以来累计的 CPU 时间，纳秒（coalition 的累计值）。
    public var cpuTimeNanos: UInt64?
    /// 功率，W：CPU + GPU + ANE 能耗（槽位 11 + 41 + 39）÷ 窗口；CPU 能耗槽不可信时为 nil。
    public var watts: Double?
    /// GPU 时间占墙钟的比例（可能超过 1，显示前钳到 1）。
    public var gpuShare: Double?
    /// ANE 功率，W（估算）。
    public var aneWatts: Double?
    /// 磁盘读 / 写，B/s（「现在」档）或字节（历史时段）。
    public var diskRead: Double?
    public var diskWrite: Double?
    /// 唤醒：次/s（「现在」档）或次数（历史时段）。
    public var wakeups: Double?
    /// pageins：页/s（只在「现在」档）。
    public var pageins: Double?
    /// 在 perflevel0 上的时间占比（只在「现在」档、槽位可信时）。
    public var perfLevel0Share: Double?
    /// 内存 footprint，字节：「现在」档为当前值，历史时段为峰值。
    public var footprint: UInt64?

    // MARK: 历史时段：总量
    /// 能耗，焦耳（CPU + GPU + ANE）；有分钟的能耗不可信时为 nil。
    public var energyJoules: Double?
    /// GPU 时间，纳秒。
    public var gpuTimeNanos: UInt64?
    /// ANE 能耗，焦耳。
    public var aneJoules: Double?
    /// 时段内有记录的分钟数（应用活跃的分钟）。
    public var activeMinutes: Int?
    /// 能耗只合计了已知的分钟（有分钟的槽位核对未通过），偏低。
    public var energyPartial: Bool
    /// 时段内阻止睡眠（含显示器睡眠）的时长，秒（D69，断言区间的并集按条累加，同一时刻多条会重复计）。
    public var sleepPreventionSeconds: Double?

    /// 持有的电源断言（D69）：「现在」档是当前的，历史时段是时段内出现过的。
    public var assertions: [PowerAssertion]

    public init(
        id: String, key: String, name: String, appPath: String?, isApp: Bool, coalitionID: UInt64? = nil,
        representativePID: Int32? = nil, memberCount: Int? = nil, topMemberName: String? = nil, cpu: Double? = nil,
        cpuTimeNanos: UInt64? = nil, watts: Double? = nil, gpuShare: Double? = nil, aneWatts: Double? = nil,
        diskRead: Double? = nil, diskWrite: Double? = nil, wakeups: Double? = nil, pageins: Double? = nil,
        perfLevel0Share: Double? = nil, footprint: UInt64? = nil, energyJoules: Double? = nil, gpuTimeNanos: UInt64? = nil,
        aneJoules: Double? = nil, activeMinutes: Int? = nil, energyPartial: Bool = false, sleepPreventionSeconds: Double? = nil,
        assertions: [PowerAssertion] = []
    ) {
        self.energyPartial = energyPartial
        self.sleepPreventionSeconds = sleepPreventionSeconds
        self.id = id
        self.key = key
        self.name = name
        self.appPath = appPath
        self.isApp = isApp
        self.coalitionID = coalitionID
        self.representativePID = representativePID
        self.memberCount = memberCount
        self.topMemberName = topMemberName
        self.cpu = cpu
        self.cpuTimeNanos = cpuTimeNanos
        self.watts = watts
        self.gpuShare = gpuShare
        self.aneWatts = aneWatts
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.wakeups = wakeups
        self.pageins = pageins
        self.perfLevel0Share = perfLevel0Share
        self.footprint = footprint
        self.energyJoules = energyJoules
        self.gpuTimeNanos = gpuTimeNanos
        self.aneJoules = aneJoules
        self.activeMinutes = activeMinutes
        self.assertions = assertions
    }

    /// 持有阻止睡眠（含阻止显示器睡眠）的断言。
    public var preventsSleep: Bool { assertions.contains { $0.kind.preventsSleep } }

    public func matches(_ category: AppActivityCategory) -> Bool {
        switch category {
        case .all: true
        case .apps: isApp
        case .background: !isApp
        case .preventingSleep: preventsSleep
        }
    }
}

/// 「现在」档整张表与合计（D67 AA2）。
public struct AppActivitySnapshot: Hashable, Sendable {
    public var time: Date
    /// 窗口长度，秒。
    public var seconds: Double
    public var rows: [AppActivityRow]
    /// 全部 coalition 的 CPU + GPU + ANE 功率合计，W；能耗槽不可信时为 nil。
    public var totalWatts: Double?
    /// CPU 能耗等辅助槽是否可信（coalition 自检 S4）。
    public var slotsTrusted: Bool

    public init(time: Date, seconds: Double, rows: [AppActivityRow], totalWatts: Double?, slotsTrusted: Bool) {
        self.time = time
        self.seconds = seconds
        self.rows = rows
        self.totalWatts = totalWatts
        self.slotsTrusted = slotsTrusted
    }
}

// MARK: - 电源断言（D69）

/// 断言的归类：只按 `AssertionTrueType` 判断。
public enum PowerAssertionKind: String, Hashable, Codable, Sendable {
    /// `PreventUserIdleSystemSleep`、`PreventSystemSleep`。
    case preventSleep
    /// `PreventUserIdleDisplaySleep`。
    case preventDisplaySleep
    /// 其余（`UserIsActive`、`ExternalMedia`、`BackgroundTask` 等）：不阻止睡眠。
    case other

    public init(trueType: String) {
        switch trueType {
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion": self = .preventSleep
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": self = .preventDisplaySleep
        default: self = .other
        }
    }

    /// 阻止系统或显示器睡眠。
    public var preventsSleep: Bool { self != .other }
}

/// 一条（合并后的）电源断言。同一进程、同一类型、同一名字的多条合并为一条，`count` 记条数。
public struct PowerAssertion: Hashable, Codable, Sendable {
    /// 断言算到谁头上：有 `AssertionOnBehalfOfPID` 时是被代理的进程，否则是持有进程。
    public var pid: Int32
    /// 实际持有断言的进程（代他人持有时与 `pid` 不同，例如 coreaudiod）。
    public var holderPID: Int32
    public var holderName: String
    /// `AssertionTrueType`（没有时取 `AssertType`）。
    public var type: String
    public var kind: PowerAssertionKind
    /// `AssertName`。
    public var name: String
    /// 合并的条数。
    public var count: Int
    /// 最早一条的开始时刻（`AssertStartWhen`）；读不到时为 nil。
    public var since: Date?
    /// `pid` 所在的 resource coalition；读不到时为 nil。
    public var coalitionID: UInt64?

    public init(
        pid: Int32, holderPID: Int32, holderName: String, type: String, name: String, count: Int = 1, since: Date? = nil,
        coalitionID: UInt64? = nil
    ) {
        self.pid = pid
        self.holderPID = holderPID
        self.holderName = holderName
        self.type = type
        self.kind = PowerAssertionKind(trueType: type)
        self.name = name
        self.count = count
        self.since = since
        self.coalitionID = coalitionID
    }

    /// 代他人持有（显示「经 <持有进程>」）。
    public var isOnBehalf: Bool { pid != holderPID }

    /// 比较开始 / 结束用的键：同一进程、类型、名字视为同一条。
    public var spanKey: String { "\(pid)|\(type)|\(name)" }
}

/// 一次读到的全部断言。
public struct PowerAssertionSnapshot: Hashable, Sendable {
    public var time: Date
    public var assertions: [PowerAssertion]

    public init(time: Date, assertions: [PowerAssertion]) {
        self.time = time
        self.assertions = assertions
    }
}
