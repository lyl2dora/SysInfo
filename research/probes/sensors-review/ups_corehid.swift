// ups_corehid.swift - READ-ONLY: public CoreHID RequestElementUpdate (GET_REPORT) on the USB UPS's Power Device (0x84) /
// Battery System (0x85) elements, to see whether load / power / voltage are readable. No set-report, no seize, no writes.
import CoreHID
import Foundation

let names: [UInt32: String] = [0x840030: "Voltage", 0x840031: "Current", 0x840032: "Frequency", 0x840033: "ApparentPower", 0x840034: "ActivePower",
  0x840035: "PercentLoad", 0x840036: "Temperature", 0x840040: "ConfigVoltage", 0x840043: "ConfigApparentPower", 0x840044: "ConfigActivePower",
  0x840053: "LowVoltageTransfer", 0x840054: "HighVoltageTransfer", 0x840057: "DelayBeforeShutdown", 0x840058: "Test", 0x84005a: "AudibleAlarmControl",
  0x850066: "RemainingCapacity", 0x850068: "RunTimeToEmpty", 0x850083: "DesignCapacity", 0x850085: "ManufactureDate", 0x85008b: "Rechargable",
  0x850044: "Charging", 0x850045: "Discharging", 0x8500d0: "ACPresent", 0x8500d1: "BatteryPresent", 0x850042: "BelowRemainingCapacityLimit",
  0x850029: "RemainingCapacityLimit", 0x85002c: "CapacityMode", 0x850067: "FullChargeCapacity"]

@main struct P { static func main() async {
    let mgr = HIDDeviceManager()
    var ref: HIDDeviceClient.DeviceReference?
    let t = Task { do { for try await n in await mgr.monitorNotifications(matchingCriteria: [.init(primaryUsage: .power(nil))]) { if case .deviceMatched(let r) = n { ref = r; break } } } catch { print("err \(error)") } }
    try? await Task.sleep(for: .seconds(1.5)); t.cancel()
    guard let ref, let c = HIDDeviceClient(deviceReference: ref) else { print("no UPS"); return }
    print("device: \(await c.product ?? "?")")
    let els = await c.elements.filter { ($0.usage.page == 0x84 || $0.usage.page == 0x85) && ($0.type == .feature || $0.type == .input) }
    print("power/battery-page input+feature elements: \(els.count)")
    for e in els {
        let req = HIDDeviceClient.RequestElementUpdate(elements: [e])
        let r = await c.updateElements([req], timeout: .seconds(2))
        let key = UInt32(e.usage.page) << 16 | UInt32(e.usage.usage ?? 0)
        let label = names[key] ?? String(format: "0x%02x/0x%02x", e.usage.page, e.usage.usage ?? 0)
        switch r[req] {
        case .success(let vals)?:
            for v in vals { print(String(format: "%-22@ type=%@ rid=%@ unit=0x%x exp=%d int=%lld phys=%@ bytes=%@", label as NSString, "\(e.type)", "\(e.reportID.map { "\($0)" } ?? "-")", e.unit ?? 0, Int(e.unitExponent ?? 0), v.integerValue(asTypeTruncatingIfNeeded: Int64.self), "\(v.physicalValue(fromTypeTruncatingIfNeeded: Int64.self, as: Double.self).map { String($0) } ?? "nil")", v.bytes.map { String(format: "%02x", $0) }.joined())) }
        case .failure(let err)?: print("\(label) type=\(e.type) ERROR \(err)")
        case nil: print("\(label) no result")
        }
    }
} }
