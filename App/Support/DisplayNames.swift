// 采集层稳定代码到界面文案的映射（D23：文案统一走 String Catalog），以及诊断页用到的格式化。

import Foundation
import SysCollectors
import SysModel

enum DisplayNames {
    static func collector(_ id: CollectorID) -> String {
        switch id.rawValue {
        case "cpu.load": String(localized: "CPU 负载")
        case "app.self": String(localized: "本进程开销")
        default: id.rawValue
        }
    }

    static func status(_ status: CollectorStatus) -> String {
        switch status {
        case .ok: String(localized: "正常")
        case .degraded: String(localized: "降级")
        case .unavailable: String(localized: "不可用")
        }
    }

    /// 自检项的名称；未知代码原样显示。
    static func selfTestCheck(_ name: String) -> String {
        switch name {
        case "cpu.load.read": String(localized: "读取每核 tick")
        case "cpu.load.coreCount": String(localized: "核数与 hw.logicalcpu 一致")
        case "cpu.load.nonzero": String(localized: "计数器非零")
        case "cpu.load.monotonic": String(localized: "两次读数单调不减")
        case "app.self.timebase": String(localized: "mach 时基")
        case "app.self.read": String(localized: "读取 proc_pid_rusage")
        case "app.self.footprint": String(localized: "内存 footprint")
        case "app.self.cpuUnits": String(localized: "CPU 时间单位校验")
        default: name
        }
    }

    static func demandSource(_ source: DemandSource) -> String {
        switch source {
        case .menubarCPU: String(localized: "菜单栏 CPU")
        case .panel: String(localized: "面板")
        case .diagnostics: String(localized: "诊断页")
        case .cli: String(localized: "命令行")
        default: source.rawValue
        }
    }

    static func throttleReason(_ reason: ThrottleReason) -> String {
        switch reason {
        case .lowPowerMode: String(localized: "低电量模式")
        case .thermalPressure: String(localized: "过热")
        case .onBatteryPower: String(localized: "UPS/电池供电")
        case .screenLocked: String(localized: "锁屏")
        case .displayAsleep: String(localized: "显示器睡眠")
        case .manual: String(localized: "手动")
        }
    }

    static func throttleFactor(_ factor: ThrottleFactor) -> String {
        switch factor {
        case .normal: String(localized: "不降频")
        case .slowed(let multiplier): String(localized: "间隔 ×\(multiplier)")
        case .paused: String(localized: "暂停前台采样")
        }
    }

    static func interval(_ interval: SamplingInterval) -> String {
        String(localized: "\(interval.rawValue) 秒")
    }
}

enum Formatting {
    /// 纳秒 → 毫秒，保留两位小数（与地区无关，便于和日志、命令行输出对照）。
    static func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.2f ms", Double(nanos) / 1e6)
    }

    /// 内存按 1024 换算，与活动监视器一致（K24）。
    static func memory(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
