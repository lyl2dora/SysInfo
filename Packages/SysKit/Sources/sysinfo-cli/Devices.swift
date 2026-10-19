// sysinfo-cli devices（电源设备设计 §7，D84）：设备清单、主 UPS 的 HID 遥测与 IOPS 对照；--watch 事件驱动地打印变化。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runDevices(watchSeconds: Double?, json: Bool) -> Int32 {
        let monitor = PowerSourceMonitor.shared
        let sources = PowerSourceCollector(monitor: monitor)
        let ups = UPSTelemetryCollector(monitor: monitor)
        for collector in [sources, ups] as [any Collector] {
            let result = collector.selfTest()
            for check in result.checks where !check.passed {
                printError("    \(check.severity == .advisory ? "!" : "✗") \(check.name)：\(check.detail)")
            }
        }
        let wall0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        _ = ups.sample(at: .now())
        let cost = (
            cpu: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6,
            wall: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wall0) / 1e6)
        let snapshot = monitor.latest

        if json {
            struct Reading: Encodable {
                var vendorID: Int, productID: Int, product: String
                var telemetry: UPSTelemetry?, staticInfo: UPSStaticInfo
                var defaultedUnits: [String], missingKeys: [String]
            }
            struct Record: Encodable {
                var snapshot: PowerDeviceSnapshot
                var ups: [Reading]
                var comparison: String
            }
            let record = Record(
                snapshot: snapshot,
                ups: ups.readings.map {
                    Reading(
                        vendorID: $0.vendorID, productID: $0.productID, product: $0.product, telemetry: $0.telemetry,
                        staticInfo: $0.staticInfo, defaultedUnits: $0.defaultedUnits, missingKeys: $0.missingKeys)
                }, comparison: ups.diagnostics.lastComparison)
            if let data = try? makeEncoder().encode(record) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            print(machineLine())
            printDevices(snapshot, ups: ups)
            print(String(format: "HID 读取：%.2f ms CPU，%.1f ms 墙钟 · %@", cost.cpu, cost.wall, ups.diagnostics.lastComparison))
        }

        guard let watchSeconds else { return 0 }
        // 放电实测时输出常重定向到文件：按行刷新，中途查看或进程被结束都不丢记录。
        setvbuf(stdout, nil, _IOLBF, 0)
        let start = Date()
        print("事件驱动地观察 \(Int(watchSeconds)) s …")
        let observation = monitor.observe { snapshot in
            let t = Date().timeIntervalSince(start)
            print(String(format: "[%6.1f s] 第 %llu 版（通知累计 %llu 次）", t, monitor.generation, monitor.status.notifyCount))
            printDevices(snapshot, ups: nil)
        }
        // 放电实测时顺带看 HID 状态位：每 5 s 读一次 UPS。
        var next = Date()
        while Date().timeIntervalSince(start) < watchSeconds {
            if Date() >= next, let reading = { _ = ups.sample(at: .now()); return ups.primaryReading }() {
                let t = Date().timeIntervalSince(start)
                print(String(format: "[%6.1f s] HID %@", t, telemetryLine(reading)))
                next = Date().addingTimeInterval(5)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        observation.cancel()
        return 0
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    private static func printDevices(_ snapshot: PowerDeviceSnapshot, ups: UPSTelemetryCollector?) {
        if snapshot.devices.isEmpty { print("没有电源设备（UPS、电池、配件）") }
        if !snapshot.accessoriesAvailable { print("! 私有配件接口不可用：只列出 UPS 与内置电池") }
        for device in snapshot.devices {
            var head = ["\(kindName(device.kind))  \(device.name.isEmpty ? "（无名）" : device.name)"]
            if let transport = device.transport { head.append(transport) }
            switch device.powerSourceState {
            case .external: head.append("外接电源")
            case .battery: head.append("电池供电")
            case .unknown: break
            }
            if device.kind != .accessory {
                head.append(percent(device.level))
                if let tte = device.timeToEmpty { head.append(String(format: "剩余 %.0f min", tte / 60)) }
                if let ttf = device.timeToFull { head.append(String(format: "充满还要 %.0f min", ttf / 60)) }
                if let v = device.inputVoltage { head.append(String(format: "输入 %.0f V", v)) }
            }
            print(head.joined(separator: " · "))
            if device.kind == .accessory {
                let parts = device.parts.filter { $0.role != .combined }.map { part -> String in
                    var text = "\(partName(part.role)) \(percent(part.level))"
                    if part.isCharging { text += " 充电中" }
                    return text
                }
                print("    " + parts.joined(separator: " · "))
            }
            if device.kind == .ups, let ups {
                let reading = ups.readings.first { $0.vendorID == device.vendorID && $0.productID == device.productID }
                if let reading { print("    HID " + telemetryLine(reading)) }
                if let info = reading?.staticInfo { print("    " + staticLine(info)) }
                if let reading, !reading.defaultedUnits.isEmpty { print("    ! 按默认单位：\(reading.defaultedUnits.joined(separator: ", "))") }
                if let reading, !reading.missingKeys.isEmpty { print("    ! 缺少：\(reading.missingKeys.joined(separator: ", "))") }
            }
        }
    }

    private static func telemetryLine(_ reading: UPSTelemetryCollector.Reading) -> String {
        guard let t = reading.telemetry else { return "读取失败" }
        var parts = ["电量 \(percent(t.charge))"]
        if let r = t.runtime { parts.append(String(format: "剩余 %.0f s", r)) }
        parts.append("负载 \(percent(t.load))" + (t.loadPower.map { String(format: "（约 %.0f W）", $0) } ?? ""))
        if let v = t.inputVoltage { parts.append(String(format: "输入 %.1f V", v)) }
        if let v = t.batteryVoltage { parts.append(String(format: "电池 %.2f V", v)) }
        var flags: [String] = []
        if t.flags.contains(.acPresent) { flags.append("AC") }
        if t.flags.contains(.charging) { flags.append("充电") }
        if t.flags.contains(.discharging) { flags.append("放电") }
        let alarms = t.flags.intersection(.alarms)
        if !alarms.isEmpty { flags.append("异常 0x\(String(alarms.rawValue, radix: 16))") }
        parts.append("状态 " + (flags.isEmpty ? "—" : flags.joined(separator: "+")))
        return parts.joined(separator: " · ")
    }

    private static func staticLine(_ info: UPSStaticInfo) -> String {
        var parts: [String] = []
        if let w = info.ratedActivePower { parts.append(String(format: "额定 %.0f W", w)) }
        if let v = info.ratedInputVoltage { parts.append(String(format: "额定输入 %.0f V", v)) }
        if let lo = info.lowTransferVoltage, let hi = info.highTransferVoltage { parts.append(String(format: "切换 %.0f–%.0f V", lo, hi)) }
        if let v = info.batteryNominalVoltage { parts.append(String(format: "电池额定 %.0f V", v)) }
        if let d = info.manufactureDate, let y = d.year, let m = d.month, let day = d.day {
            parts.append(String(format: "生产 %04d-%02d-%02d", y, m, day))
        }
        if let t = info.selfTestResult { parts.append("自检 \(t)") }
        if let l = info.remainingCapacityLimit { parts.append("低电量关机 \(percent(l))") }
        return parts.isEmpty ? "（静态项读不到）" : parts.joined(separator: " · ")
    }

    private static func kindName(_ kind: PowerDeviceKind) -> String {
        switch kind {
        case .ups: "UPS "
        case .internalBattery: "电池"
        case .accessory: "配件"
        }
    }

    private static func partName(_ role: PowerDevicePartRole) -> String {
        switch role {
        case .main: "电量"
        case .combined: "合计"
        case .left: "左耳"
        case .right: "右耳"
        case .case: "充电盒"
        case .other(let name): name
        }
    }
}
