// Probe: primary interface, SC interface list, DNS (Stats method + global), VPN heuristics, NWPathMonitor snapshot.
import Foundation
import SystemConfiguration
import Network
import CFNetwork

func p(_ s: String) { print(s); fflush(stdout) }

// 1. Stats method: State:/Network/Global/IPv4 PrimaryInterface (readers.swift:112)
p("== SCDynamicStore global keys")
for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS", "State:/Network/Global/Proxies"] {
    if let v = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any] {
        let short = v.filter { !["__SCOPED__"].contains($0.key) }
        p("\(key): \(short)")
    } else { p("\(key): nil") }
}

// Store-wide key listing to discover VPN / service keys
if let store = SCDynamicStoreCreate(nil, "probe" as CFString, nil, nil) {
    let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/.*/IPv4" as CFString) as? [String]) ?? []
    p("IPv4-configured interfaces (State:/Network/Interface/*/IPv4): \(keys)")
    let svc = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*" as CFString) as? [String]) ?? []
    p("State:/Network/Service keys: \(svc.sorted())")
    let vpnKeys = svc.filter { $0.contains("VPN") || $0.contains("PPP") || $0.contains("IPSec") }
    p("VPN/PPP/IPSec service keys: \(vpnKeys)")
    // NetworkExtension-based VPN state lives under these when a VPN is up
    let neKeys = (SCDynamicStoreCopyKeyList(store, ".*NetworkExtension.*|.*/VPN.*" as CFString) as? [String]) ?? []
    p("NE/VPN-ish keys: \(neKeys)")
}

// 2. SCNetworkInterfaceCopyAll (Stats getDetails readers.swift:377, isAvailable main.swift:239)
p("\n== SCNetworkInterfaceCopyAll")
for any in SCNetworkInterfaceCopyAll() as NSArray {
    let i = any as! SCNetworkInterface
    let bsd = SCNetworkInterfaceGetBSDName(i) as String? ?? "-"
    let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? "-"
    let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? "-"
    let mac = SCNetworkInterfaceGetHardwareAddressString(i) as String? ?? "-"
    p("  \(bsd)\t type=\(type)\t name=\(name)\t hw=\(mac)")
}

// 3. DNS: Stats method (service-scoped) vs global
p("\n== DNS")
let primary = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String ?? ""
p("primary=\(primary)")
if let prefs = SCPreferencesCreate(nil, "probe" as CFString, nil), let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
    for s in services {
        guard let intf = SCNetworkServiceGetInterface(s), let bsd = SCNetworkInterfaceGetBSDName(intf), let sid = SCNetworkServiceGetServiceID(s) else { continue }
        let name = SCNetworkServiceGetName(s) as String? ?? "-"
        let dns = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(sid)/DNS" as CFString) as? [String: Any]
        let ipv4 = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(sid)/IPv4" as CFString) as? [String: Any]
        p("  service \(name) [\(bsd)] enabled=\(SCNetworkServiceGetEnabled(s)) dns=\(dns?["ServerAddresses"] ?? "nil") ipv4=\(ipv4?["Addresses"] ?? "nil") router=\(ipv4?["Router"] ?? "nil")")
    }
}
// res_ninit tested separately in dns.c

// 4. Stats VPN heuristic (readers.swift:128-133): CFNetworkCopySystemProxySettings __SCOPED__ keys
p("\n== VPN heuristics")
if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
    let scopes = settings["__SCOPED__"] as? [String: Any] ?? [:]
    let keys = scopes.keys.sorted()
    let statsVPN = !keys.filter { $0.contains("tap") || $0.contains("tun") || $0.contains("ppp") || $0.contains("ipsec") }.isEmpty
    p("__SCOPED__ keys=\(keys) -> Stats vpnConnection=\(statsVPN)")
}
// Alternative: utun with a routable (non link-local) address, or primary interface is utun/ipsec/ppp
var ifap: UnsafeMutablePointer<ifaddrs>?
var tunAddrs: [String: [String]] = [:]
if getifaddrs(&ifap) == 0 {
    var ptr = ifap
    while let cur = ptr {
        let name = String(cString: cur.pointee.ifa_name)
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tap") || name.hasPrefix("tun"),
           let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            tunAddrs[name, default: []].append(String(cString: host))
        }
        ptr = cur.pointee.ifa_next
    }
    freeifaddrs(ifap)
}
let routable = tunAddrs.filter { $0.value.contains { !$0.hasPrefix("fe80") } }
p("tunnel interfaces+addrs=\(tunAddrs.sorted { $0.key < $1.key })")
p("tunnels with routable addr (VPN-likely)=\(routable.keys.sorted()) primaryIsTunnel=\(primary.hasPrefix("utun") || primary.hasPrefix("ipsec") || primary.hasPrefix("ppp"))")
// SCNetworkConnection-based (legacy VPN services configured in System Settings)
if let prefs = SCPreferencesCreate(nil, "probe" as CFString, nil), let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
    let vpnServices = services.filter {
        guard let i = SCNetworkServiceGetInterface($0), let t = SCNetworkInterfaceGetInterfaceType(i) else { return false }
        return [kSCNetworkInterfaceTypePPP, kSCNetworkInterfaceTypeIPSec, kSCNetworkInterfaceTypeL2TP, kSCNetworkInterfaceTypePPTP, "VPN" as CFString].contains(t)
    }
    p("configured SC VPN services: \(vpnServices.map { SCNetworkServiceGetName($0) as String? ?? "?" })")
}

// 5. NWPathMonitor snapshot (first update)
p("\n== NWPathMonitor")
let sem = DispatchSemaphore(value: 0)
let mon = NWPathMonitor()
var once = false
mon.pathUpdateHandler = { path in
    if once { return }; once = true
    p("status=\(path.status) expensive=\(path.isExpensive) constrained=\(path.isConstrained) ultraConstrained=\(path.isUltraConstrained) linkQuality=\(path.linkQuality) v4=\(path.supportsIPv4) v6=\(path.supportsIPv6) dns=\(path.supportsDNS)")
    p("availableInterfaces=\(path.availableInterfaces.map { "\($0.name)(\($0.type), idx \($0.index))" })")
    p("gateways=\(path.gateways)")
    p("usesWired=\(path.usesInterfaceType(.wiredEthernet)) usesWifi=\(path.usesInterfaceType(.wifi)) usesOther=\(path.usesInterfaceType(.other))")
    p("debugDescription=\(path.debugDescription)")
    sem.signal()
}
mon.start(queue: .global())
_ = sem.wait(timeout: .now() + 3)
mon.cancel()

// Per-interface-type monitors
for t in [NWInterface.InterfaceType.wifi, .wiredEthernet, .other] {
    let s2 = DispatchSemaphore(value: 0)
    let m = NWPathMonitor(requiredInterfaceType: t)
    m.pathUpdateHandler = { path in
        p("requiredInterfaceType=\(t): status=\(path.status) ifs=\(path.availableInterfaces.map { $0.name }) linkQuality=\(path.linkQuality)")
        s2.signal()
    }
    m.start(queue: .global())
    _ = s2.wait(timeout: .now() + 2)
    m.cancel()
}

// 6. SCNetworkReachability flags (Kit/plugins/Reachability.swift:30) - deprecated since macOS 14.4
var zero = sockaddr(); zero.sa_len = UInt8(MemoryLayout<sockaddr>.size); zero.sa_family = sa_family_t(AF_INET)
if let r = SCNetworkReachabilityCreateWithAddress(nil, &zero) {
    var flags = SCNetworkReachabilityFlags()
    let ok = SCNetworkReachabilityGetFlags(r, &flags)
    p("\nSCNetworkReachability(0.0.0.0) ok=\(ok) flags=0x\(String(flags.rawValue, radix: 16)) reachable=\(flags.contains(.reachable))")
}
