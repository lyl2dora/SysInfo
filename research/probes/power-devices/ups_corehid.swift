// 电源设备模块边界探针：公开 CoreHID 读 UPS（usage page 0x84/0x85），只用 GET 方向，不写设备。
// 验证：按 page 0x84 匹配是否触发授权；元素清单；一次全量 feature 读取的墙钟与 CPU；关键值换算。
// 编译：xcrun swiftc -O ups_corehid.swift -o ups_corehid
// 用法：./ups_corehid [重复次数，默认 20] [间隔秒，默认 1]
import CoreHID
import Foundation

let rounds = Int(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let interval = Double(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1

func processCPUMicros() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e6 + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec)
}

/// HID 单位：只处理本探针关心的几种（SI linear 系统下的伏特、秒）。
func describeUnit(_ unit: UInt32?, _ exp: Int8?) -> String {
    guard let unit, unit != 0 else { return "" }
    return String(format: " unit=0x%x exp=%d", unit, exp ?? 0)
}

/// HID 单位指数是 4 位有符号数。
func decodeExponent(_ e: Int8?) -> Int {
    guard let e else { return 0 }
    let v = Int(e) & 0xF
    return v >= 8 ? v - 16 : v
}

/// 按 HID 单位换算成 SI：电压（0xf0d121，cm² g s⁻³ A⁻¹ = 1e-7 V）、秒（0x1001）、瓦（0xd121，cm² g s⁻³ = 1e-7 W）。
func siValue(_ raw: Int64, unit: UInt32?, exp: Int8?) -> String {
    let e = decodeExponent(exp)
    switch unit {
    case 0xf0d121: return String(format: "%.3f V", Double(raw) * pow(10, Double(e - 7)))
    case 0xd121: return String(format: "%.1f W", Double(raw) * pow(10, Double(e - 7)))
    case 0x1001: return String(format: "%.0f s", Double(raw) * pow(10, Double(e)))
    default: return ""
    }
}

let pageNames: [UInt16: String] = [0x84: "PD", 0x85: "BS"]
let usageNames: [UInt32: String] = [
    0x84_0002: "PresentStatus", 0x84_0012: "Battery", 0x84_0016: "PowerConverter", 0x84_001a: "Input", 0x84_001c: "Output",
    0x84_0024: "PowerSummary", 0x84_0030: "Voltage", 0x84_0031: "Current", 0x84_0032: "Frequency", 0x84_0035: "PercentLoad",
    0x84_0040: "ConfigVoltage", 0x84_0044: "ConfigActivePower", 0x84_0053: "LowVoltageTransfer", 0x84_0054: "HighVoltageTransfer",
    0x84_0057: "DelayBeforeShutdown", 0x84_0058: "Test", 0x84_005a: "AudibleAlarmControl", 0x84_0065: "Overload",
    0x84_0069: "ShutdownImminent", 0x84_0073: "CommunicationLost", 0x84_00fd: "iManufacturer", 0x84_00fe: "iProduct", 0x84_00ff: "iSerialNumber",
    0x85_0029: "RemainingCapacityLimit", 0x85_002a: "RemainingTimeLimit", 0x85_002c: "CapacityMode", 0x85_0042: "BelowRemainingCapacityLimit",
    0x85_0043: "RemainingTimeLimitExpired", 0x85_0044: "Charging", 0x85_0045: "Discharging", 0x85_004b: "NeedReplacement",
    0x85_0066: "RemainingCapacity", 0x85_0067: "FullChargeCapacity", 0x85_0068: "RunTimeToEmpty", 0x85_0083: "DesignCapacity",
    0x85_0085: "ManufacturerDate", 0x85_0089: "iDeviceChemistry", 0x85_008b: "Rechargeable", 0x85_008c: "WarningCapacityLimit",
    0x85_008f: "iOEMInformation", 0x85_00d0: "ACPresent", 0x85_00d1: "BatteryPresent", 0x85_00db: "VoltageNotRegulated",
]
func name(_ u: HIDUsage) -> String {
    let key = UInt32(u.page) << 16 | UInt32(u.usage ?? 0)
    return usageNames[key] ?? String(format: "%@:0x%02x", pageNames[u.page] ?? String(format: "0x%x", u.page), u.usage ?? 0)
}

@main
struct Probe {
    static func main() async throws {
        print("=== \(Date())  rounds=\(rounds) interval=\(interval)s")
        let manager = HIDDeviceManager()
        // usage 为 nil：看能否按整页匹配（UPS 的 primaryUsage 是 0x84:0x04）。
        let criteria = [HIDDeviceManager.DeviceMatchingCriteria(primaryUsage: HIDUsage(page: 0x84, usage: nil))]
        let cpu0 = processCPUMicros()
        let t0 = ContinuousClock.now
        // 没有设备时 stream 不会结束，用 task group 与 3 s 超时赛跑。
        let found: HIDDeviceClient? = try await withThrowingTaskGroup(of: HIDDeviceClient?.self) { group in
            group.addTask {
                for try await n in await manager.monitorNotifications(matchingCriteria: criteria) {
                    if case let .deviceMatched(ref) = n, let c = HIDDeviceClient(deviceReference: ref) { return c }
                }
                return nil
            }
            group.addTask { try await Task.sleep(for: .seconds(3)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let client = found else { print("no device on page 0x84"); return }
        print("matched in \(ContinuousClock.now - t0), cpu \(Int(processCPUMicros() - cpu0)) us")
        let (pn, tr, vid, pid, pu) = (await client.product, await client.transport, await client.vendorID, await client.productID, await client.primaryUsage)
        print("product=\(pn ?? "?") transport=\(String(describing: tr)) vendor=\(vid) productID=\(pid) primaryUsage=\(pu)")

        let all = await client.elements
        let interesting = all.filter { [0x84, 0x85].contains($0.usage.page) && $0.type == .feature }
        print("elements total=\(all.count) feature(0x84/0x85)=\(interesting.count) input=\(all.filter { $0.type == .input }.count)")
        let reportIDs = Set(interesting.compactMap { $0.reportID?.rawValue }).sorted()
        print("feature report IDs (\(reportIDs.count)): \(reportIDs)")

        var cpu: [Double] = []
        var wall: [Duration] = []
        for r in 0..<rounds {
            let c0 = processCPUMicros(); let w0 = ContinuousClock.now
            let req = HIDDeviceClient.RequestElementUpdate(elements: interesting, pollDevice: true)
            let result = await client.updateElements([req], timeout: .seconds(2))
            wall.append(ContinuousClock.now - w0); cpu.append(processCPUMicros() - c0)
            guard case let .success(values)? = result[req] else { print("round \(r): failed \(String(describing: result[req]))"); continue }
            if r == 0 || r == rounds - 1 {
                print("-- round \(r) values (\(values.count))")
                var seen = Set<String>()
                for v in values {
                    let e = v.element
                    let line = "\(name(e.parentCollection.usage)).\(name(e.usage)) rid=\(e.reportID?.rawValue ?? 0)"
                    guard seen.insert(line).inserted else { continue }
                    let raw = v.integerValue(asTypeTruncatingIfNeeded: Int64.self)
                    print("   \(line) = \(raw)\(describeUnit(e.unit, e.unitExponent)) \(siValue(raw, unit: e.unit, exp: e.unitExponent))")
                }
            } else {
                let pick = values.first { $0.element.usage == HIDUsage(page: 0x84, usage: 0x35) }
                print("round \(r): load=\(pick.map { $0.integerValue(asTypeTruncatingIfNeeded: Int64.self) } ?? -1)% wall=\(wall.last!)")
            }
            try await Task.sleep(for: .seconds(interval))
        }
        let sc = cpu.sorted(), sw = wall.sorted()
        print(String(format: "full feature read: cpu p50=%.0f us p90=%.0f us max=%.0f us", sc[sc.count / 2], sc[sc.count * 9 / 10], sc.last!))
        print("wall p50=\(sw[sw.count / 2]) p90=\(sw[sw.count * 9 / 10]) max=\(sw.last!)")

        // 只读常用几项（电量、剩余时间、负载、输入电压、状态位）的开销对照。
        let core: Set<UInt32> = [0x85_0066, 0x85_0068, 0x84_0035, 0x85_00d0, 0x85_0044, 0x85_0045, 0x85_004b, 0x84_0065]
        let coreEls = interesting.filter { core.contains(UInt32($0.usage.page) << 16 | UInt32($0.usage.usage ?? 0)) }
            + interesting.filter { $0.usage == HIDUsage(page: 0x84, usage: 0x30) && $0.parentCollection.usage == HIDUsage(page: 0x84, usage: 0x1a) }
        var cc: [Double] = []
        for _ in 0..<rounds {
            let c0 = processCPUMicros()
            _ = await client.updateElements([HIDDeviceClient.RequestElementUpdate(elements: coreEls, pollDevice: true)], timeout: .seconds(2))
            cc.append(processCPUMicros() - c0)
        }
        cc.sort()
        print(String(format: "core read (%d elements, %d reports): cpu p50=%.0f us p90=%.0f us", coreEls.count, Set(coreEls.compactMap { $0.reportID }).count, cc[cc.count / 2], cc[cc.count * 9 / 10]))
    }
}
