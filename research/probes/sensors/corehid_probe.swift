// corehid_probe.swift - does public CoreHID (macOS 15+) expose the SoC/PMU sensor services?
// Build: xcrun swiftc -O corehid_probe.swift -o corehid_probe
import CoreHID
import Foundation

func collect(_ label: String, _ criteria: [HIDDeviceManager.DeviceMatchingCriteria], seconds: Double = 2.0) async {
    let mgr = HIDDeviceManager()
    var refs: [HIDDeviceClient.DeviceReference] = []
    let task = Task {
        do {
            for try await n in await mgr.monitorNotifications(matchingCriteria: criteria) {
                if case .deviceMatched(let r) = n { refs.append(r) }
            }
        } catch { print("  [\(label)] stream error: \(error)") }
    }
    try? await Task.sleep(for: .seconds(seconds))
    task.cancel()
    print("== \(label): \(refs.count) device(s)")
    for r in refs {
        guard let c = HIDDeviceClient(deviceReference: r) else { print("  <HIDDeviceClient init failed>"); continue }
        let du = await c.deviceUsages
        let pu = await c.primaryUsage; let product = await c.product, mfr = await c.manufacturer, tr = await c.transport, bi = await c.isBuiltIn
        let usages = du.map { "0x" + String($0.page, radix: 16) + "/" + ($0.usage.map { "0x" + String($0, radix: 16) } ?? "-") }
        let els = await c.elements.count
        print("  product=\(product ?? "nil") mfr=\(mfr ?? "nil") transport=\(String(describing: tr)) builtIn=\(bi) primary=0x\(String(pu.page, radix: 16))/\(pu.usage.map { String($0, radix: 16) } ?? "-") usages=\(usages) elements=\(els)")
    }
}

@main struct Probe {
    static func main() async {
        await collect("ALL devices (empty criteria)", [.init()])
        await collect("AppleVendor temp 0xff00/0x05", [.init(primaryUsage: .generic(0xff00, 0x05))])
        await collect("AppleVendor power 0xff08/0x02", [.init(primaryUsage: .generic(0xff08, 0x02))])
        await collect("HID Sensors page 0x20", [.init(primaryUsage: .sensors(nil))])
        await collect("Power device page 0x84", [.init(primaryUsage: .power(nil))])
    }
}
