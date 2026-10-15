// 采集层稳定代码到界面文案的映射（D23：文案统一走 String Catalog），以及诊断页用到的格式化。

import Foundation
import SwiftUI
import SysCollectors
import SysModel
import SysStore

enum DisplayNames {
    static func collector(_ id: CollectorID) -> String {
        switch id.rawValue {
        case "cpu.load": String(localized: "CPU 负载")
        case "cpu.freq": String(localized: "CPU 频率")
        case "cpu.misc": String(localized: "负载均值与中断")
        case "cpu.sensors": String(localized: "温度与功耗")
        case "app.coalition": String(localized: "应用活动")
        case "cpu.irq.devices": String(localized: "中断来源")
        case "cpu.freq.cores": String(localized: "逐核频率")
        case "app.self": String(localized: "本进程开销")
        case "power.rail": String(localized: "整机功率")
        case "power.sensors": String(localized: "SoC 功率、最热点与风扇")
        case "power.gpu": String(localized: "GPU 功率")
        case "power.pmgr": String(localized: "30 分钟分部件能耗")
        case "sensors.catalog": String(localized: "传感器目录")
        case "memory.vm": String(localized: "内存")
        case "memory.bandwidth": String(localized: "DRAM 带宽")
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
        case "cpu.load.coreCount": String(localized: "核数与 hw.logicalcpu_max 一致")
        case "cpu.load.nonzero": String(localized: "计数器非零")
        case "cpu.load.monotonic": String(localized: "两次读数单调不减")
        case "app.self.timebase": String(localized: "mach 时基")
        case "app.self.read": String(localized: "读取 proc_pid_rusage")
        case "app.self.footprint": String(localized: "内存 footprint")
        case "app.self.cpuUnits": String(localized: "CPU 时间单位校验")
        case "memory.vm.sysctl": String(localized: "读取内存与页面队列 sysctl")
        case "memory.vm.hostStatistics": String(localized: "host_statistics64 返回 rev6")
        case "memory.vm.queueSum": String(localized: "页面队列之和与可用内存一致")
        case "memory.vm.pressure": String(localized: "读取内存压力")
        case "memory.bandwidth.ioreport": String(localized: "IOReport 可用")
        case "memory.bandwidth.channels": String(localized: "找到 DCS BW 通道")
        default: name
        }
    }

    static func demandSource(_ source: DemandSource) -> String {
        switch source {
        case .menubarCPU: String(localized: "菜单栏 CPU")
        case .panel: String(localized: "面板")
        case .diagnostics: String(localized: "诊断页")
        case .cli: String(localized: "命令行")
        case .history: String(localized: "历史记录")
        default:
            if source.rawValue.hasPrefix("menubar.power.") {
                String(localized: "菜单栏功耗与散热")
            } else if source.rawValue.hasPrefix("menubar.cpu.") {
                String(localized: "菜单栏 CPU")
            } else if source.rawValue.hasPrefix("menubar.memory.") {
                String(localized: "菜单栏内存")
            } else {
                source.rawValue
            }
        }
    }

    /// 内存压力等级（D49）。
    static func memoryPressure(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: String(localized: "正常")
        case .warning: String(localized: "警告")
        case .critical: String(localized: "严重")
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

    /// 核档名：取内核给的名字并本地化，不认识的原样显示（D29）。
    static func perfLevel(_ name: String) -> String {
        switch name {
        case "Super": String(localized: "超级核")
        case "Performance": String(localized: "性能核")
        case "Efficiency": String(localized: "能效核")
        default: name
        }
    }

    /// 核档颜色：按名字取，不认识的按序号取备用色（D29）。
    static func perfLevelColor(_ name: String, index: Int) -> Color {
        switch name {
        case "Super": .purple
        case "Performance": .blue
        case "Efficiency": .green
        default: [Color.orange, .teal, .pink][index % 3]
        }
    }

    /// 热状态徽标（只做徽标，不参与着色，D29）；nominal 时为 nil。
    static func thermalState(_ value: Double) -> (text: String, color: Color)? {
        switch Int(value) {
        case 1: (String(localized: "偏热"), .yellow)
        case 2: (String(localized: "过热"), .orange)
        case 3: (String(localized: "严重过热"), .red)
        default: nil
        }
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

    /// 频率：Hz → 「3.12 GHz」或「980 MHz」。
    static func frequency(_ hertz: Double) -> String {
        hertz >= 1e9 ? String(format: "%.2f GHz", hertz / 1e9) : String(format: "%.0f MHz", hertz / 1e6)
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.0f °C", celsius)
    }

    static func watts(_ watts: Double) -> String {
        watts < 10 ? String(format: "%.2f W", watts) : String(format: "%.1f W", watts)
    }

    /// 刻度用：「20 W」「5 W」。
    static func wattsShort(_ watts: Double) -> String {
        watts == watts.rounded() ? String(format: "%.0f W", watts) : String(format: "%.1f W", watts)
    }

    /// 能耗：「1.23 kWh」；小于 1 kWh 时用 Wh，小数位随量级减少（「0.25 Wh」「8.4 Wh」「320 Wh」）。
    static func energy(_ joules: Double) -> String {
        let wh = joules / 3600
        switch wh {
        case ..<10: return String(format: "%.2f Wh", wh)
        case ..<100: return String(format: "%.1f Wh", wh)
        case ..<1000: return String(format: "%.0f Wh", wh)
        default: return String(format: "%.2f kWh", wh / 1000)
        }
    }

    /// 转速：「1000 rpm」。
    static func rpm(_ value: Double) -> String {
        String(format: "%.0f rpm", value)
    }

    /// 每秒次数：「1.2k/s」。
    static func rate(_ perSecond: Double) -> String {
        perSecond >= 1000 ? String(format: "%.1fk/s", perSecond / 1000) : String(format: "%.0f/s", perSecond)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "—"
    }
}
