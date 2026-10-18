// Probe: local IPv4/IPv6 for the primary interface.
// (a) exact replica of Stats getLocalIP (readers.swift:487-501): copies ifa_addr.pointee (a 16-byte sockaddr) then getnameinfo with sa_len
// 复刻代码适用 Stats 的 MIT 许可，见仓库根目录 THIRD_PARTY_NOTICES.md。
// (b) correct: pass ifa_addr pointer directly; plus IPv6 address flags via SIOCGIFAFLAG_IN6 to classify temporary/deprecated/secured
import Foundation
import SystemConfiguration

func p(_ s: String) { print(s); fflush(stdout) }
let ifname = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String ?? "en0"
p("primary=\(ifname) MemoryLayout<sockaddr>.size=\(MemoryLayout<sockaddr>.size) MemoryLayout<sockaddr_in6>.size=\(MemoryLayout<sockaddr_in6>.size)")

// SIOCGIFAFLAG_IN6 = _IOWR('i', 73, struct in6_ifreq); in6_ifreq is 16 (name) + 272 (union, largest member in6_ifstat/icmp6_ifstat) bytes.
// We only need ifr_addr (sockaddr_in6) in and ifru_flags6 (int) out, so use a generous raw buffer.
let IN6_IFF_ANYCAST: Int32 = 0x01, IN6_IFF_TENTATIVE: Int32 = 0x02, IN6_IFF_DUPLICATED: Int32 = 0x04, IN6_IFF_DETACHED: Int32 = 0x08,
    IN6_IFF_DEPRECATED: Int32 = 0x10, IN6_IFF_AUTOCONF: Int32 = 0x40, IN6_IFF_TEMPORARY: Int32 = 0x80, IN6_IFF_SECURED: Int32 = 0x400, IN6_IFF_DYNAMIC: Int32 = 0x100
func ioc(_ dir: UInt32, _ g: UInt32, _ n: UInt32, _ len: UInt32) -> UInt { UInt(dir | ((len & 0x1fff) << 16) | (g << 8) | n) }
let IN6_IFREQ_SIZE: UInt32 = 16 + 272
let SIOCGIFAFLAG_IN6 = ioc(0xC000_0000, UInt32(UInt8(ascii: "i")), 73, IN6_IFREQ_SIZE)
let s6 = socket(AF_INET6, SOCK_DGRAM, 0)

func flags6(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
    var buf = [UInt8](repeating: 0, count: Int(IN6_IFREQ_SIZE))
    let nameBytes = Array(ifname.utf8.prefix(15))
    buf.replaceSubrange(0..<nameBytes.count, with: nameBytes)
    withUnsafeBytes(of: sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }) { raw in
        for (k, b) in raw.enumerated() { buf[16 + k] = b }
    }
    let rc = buf.withUnsafeMutableBytes { ioctl(s6, SIOCGIFAFLAG_IN6, $0.baseAddress!) }
    if rc != 0 { return "ioctl err \(errno)" }
    let f = buf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Int32.self) }
    var out: [String] = []
    if f & IN6_IFF_TEMPORARY != 0 { out.append("temporary") }
    if f & IN6_IFF_DEPRECATED != 0 { out.append("deprecated") }
    if f & IN6_IFF_SECURED != 0 { out.append("secured") }
    if f & IN6_IFF_AUTOCONF != 0 { out.append("autoconf") }
    if f & IN6_IFF_TENTATIVE != 0 { out.append("tentative") }
    if f & IN6_IFF_DUPLICATED != 0 { out.append("duplicated") }
    if f & IN6_IFF_DETACHED != 0 { out.append("detached") }
    if f & IN6_IFF_DYNAMIC != 0 { out.append("dynamic") }
    return "0x" + String(f, radix: 16) + " " + out.joined(separator: ",")
}

var statsV4: String? = nil, statsV6: String? = nil
var ifap: UnsafeMutablePointer<ifaddrs>?
guard getifaddrs(&ifap) == 0 else { exit(1) }
var cur = ifap
while let c = cur {
    defer { cur = c.pointee.ifa_next }
    guard String(cString: c.pointee.ifa_name) == ifname, let sa = c.pointee.ifa_addr else { continue }
    let fam = sa.pointee.sa_family
    guard fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) else { continue }

    // (a) Stats replica
    var addr = sa.pointee
    var ip = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let rcA = getnameinfo(&addr, socklen_t(addr.sa_len), &ip, socklen_t(ip.count), nil, socklen_t(0), NI_NUMERICHOST)
    let a = String(cString: ip)
    // (b) correct
    var ip2 = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let rcB = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &ip2, socklen_t(ip2.count), nil, 0, NI_NUMERICHOST)
    let b = String(cString: ip2)
    let fl = fam == UInt8(AF_INET6) ? flags6(sa) : ""
    p("\(fam == UInt8(AF_INET) ? "v4" : "v6") statsReplica=\(a)(rc \(rcA)) correct=\(b)(rc \(rcB)) match=\(a == b) \(fl)")
    if fam == UInt8(AF_INET) && !a.isEmpty { statsV4 = a } else if fam == UInt8(AF_INET6) && !a.isEmpty { statsV6 = a }
}
freeifaddrs(ifap)
p("Stats would display laddr.v4=\(statsV4 ?? "nil") laddr.v6=\(statsV6 ?? "nil") (last IPv6 in getifaddrs order wins)")
// SCDynamicStore view (per-interface IPv6 state) for comparison
if let v6 = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(ifname)/IPv6" as CFString) as? [String: Any] {
    p("SCDynamicStore State:/Network/Interface/\(ifname)/IPv6 Addresses=\(v6["Addresses"] ?? "nil") Flags=\(v6["Flags"] ?? "nil")")
}
if let v4 = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(ifname)/IPv4" as CFString) as? [String: Any] {
    p("SCDynamicStore State:/Network/Interface/\(ifname)/IPv4 Addresses=\(v4["Addresses"] ?? "nil")")
}
