// Probe: connectivity-change notification channels (registration + any spontaneous events within the window).
// Channels: SCDynamicStore keys/patterns, NWPathMonitor, notify(3) keys, kernel event socket (KEV_NETWORK_CLASS), CoreWLAN events.
import Foundation
import SystemConfiguration
import Network
import CoreWLAN
import Darwin

func p(_ s: String) { let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)); print("[\(t)] \(s)"); fflush(stdout) }
let window: TimeInterval = Double(CommandLine.arguments.dropFirst().first ?? "25") ?? 25

// 1. SCDynamicStore
let cb: SCDynamicStoreCallBack = { _, keys, _ in p("SCDynamicStore changed: \(keys as? [String] ?? [])") }
if let store = SCDynamicStoreCreate(nil, "probe" as CFString, cb, nil) {
    let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS"] as CFArray
    let patterns = ["State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6", "State:/Network/Interface/.*/AirPort"] as CFArray
    let ok = SCDynamicStoreSetNotificationKeys(store, keys, patterns)
    let ok2 = SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
    p("SCDynamicStore setKeys=\(ok) setQueue=\(ok2)")
    // Link state for primary
    if let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/en0/Link" as CFString) { p("en0 Link=\(link)") }
    if let air = SCDynamicStoreCopyValue(store, "State:/Network/Interface/en1/AirPort" as CFString) { p("en1 AirPort keys=\((air as? [String: Any])?.keys.sorted() ?? [])") }
    else { p("State:/Network/Interface/en1/AirPort = nil") }
    withExtendedLifetime(store) {}
    objc_setAssociatedObject(NSObject.self, "store", store, .OBJC_ASSOCIATION_RETAIN)
}

// 2. NWPathMonitor
let mon = NWPathMonitor()
var n = 0
mon.pathUpdateHandler = { path in n += 1; p("NWPathMonitor update #\(n): \(path.debugDescription) linkQuality=\(path.linkQuality)") }
mon.start(queue: .main)

// 3. notify(3) via CFNotificationCenterGetDarwinNotifyCenter
let darwin = CFNotificationCenterGetDarwinNotifyCenter()
for name in ["com.apple.system.config.network_change", "com.apple.system.config.network_change.nwi", "com.apple.system.config.network_change.dns"] {
    CFNotificationCenterAddObserver(darwin, nil, { _, _, name, _, _ in p("darwin notify fired: \(name.map { $0.rawValue as String } ?? "?")") }, name as CFString, nil, .deliverImmediately)
    p("darwin notify observer added: \(name)")
}

// 4. Kernel event socket filtered to network class (KEV_VENDOR_APPLE=1, KEV_NETWORK_CLASS=1)
let ks = socket(PF_SYSTEM, SOCK_RAW, SYSPROTO_EVENT)
if ks < 0 { p("kernel event socket error: \(String(cString: strerror(errno)))") } else {
    var req = kev_request(vendor_code: UInt32(KEV_VENDOR_APPLE), kev_class: UInt32(KEV_NETWORK_CLASS), kev_subclass: UInt32(KEV_ANY_SUBCLASS))
    let rc = ioctl(ks, UInt(0x800c6502) /* SIOCSKEVFILT = _IOW('e', 2, struct kev_request) */, &req)
    p("kernel event socket fd=\(ks) SIOCSKEVFILT rc=\(rc) errno=\(rc == 0 ? 0 : errno)")
    let src = DispatchSource.makeReadSource(fileDescriptor: ks, queue: .main)
    src.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 2048)
        let r = read(ks, &buf, buf.count)
        guard r >= MemoryLayout<kern_event_msg>.size - 4 else { return }
        let msg = buf.withUnsafeBytes { $0.load(as: kern_event_msg.self) }
        var ifname = ""
        if msg.kev_subclass == UInt32(KEV_DL_SUBCLASS) || msg.kev_subclass == UInt32(KEV_INET_SUBCLASS) || msg.kev_subclass == UInt32(KEV_INET6_SUBCLASS) {
            // net_event_data: if_family, if_unit, if_name[IFNAMSIZ] at event_data
            let off = MemoryLayout<kern_event_msg>.offset(of: \kern_event_msg.event_data)!
            let unit = buf.withUnsafeBytes { $0.load(fromByteOffset: off + 4, as: UInt32.self) }
            let name = buf[(off + 8)..<(off + 8 + 16)].prefix { $0 != 0 }
            ifname = String(decoding: name, as: UTF8.self) + "\(unit)"
        }
        p("KEV class=\(msg.kev_class) subclass=\(msg.kev_subclass) code=\(msg.event_code) if=\(ifname)")
    }
    src.resume()
    objc_setAssociatedObject(NSObject.self, "kev", src, .OBJC_ASSOCIATION_RETAIN)
}

// 5. CoreWLAN
final class WD: NSObject, CWEventDelegate {
    func linkQualityDidChangeForWiFiInterface(withName i: String, rssi: Int, transmitRate: Double) { p("CW linkQuality \(i) rssi=\(rssi) tx=\(transmitRate)") }
    func linkDidChangeForWiFiInterface(withName i: String) { p("CW linkDidChange \(i)") }
    func ssidDidChangeForWiFiInterface(withName i: String) { p("CW ssidDidChange \(i)") }
    func bssidDidChangeForWiFiInterface(withName i: String) { p("CW bssidDidChange \(i)") }
}
let wd = WD()
CWWiFiClient.shared().delegate = wd
for e: CWEventType in [.linkQualityDidChange, .linkDidChange, .ssidDidChange, .bssidDidChange] { try? CWWiFiClient.shared().startMonitoringEvent(with: e) }

p("listening for \(Int(window)) s ...")
RunLoop.main.run(until: Date().addingTimeInterval(window))
p("done; NWPathMonitor updates=\(n)")
