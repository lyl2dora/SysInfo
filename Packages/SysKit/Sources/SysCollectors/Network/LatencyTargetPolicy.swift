// 自定义延迟地址的规则（D102）：格式校验，以及「不向与本机同网段的其他设备发包」。
//
// - 格式：IPv4 / IPv6 字面量（IPv6 可带 %scope），或合法主机名（RFC 1123：每段 1–63 个字母、数字、连字符，
//   不以连字符开头或结尾，总长不超过 253，可带结尾的点）。不合法的不发包，也不做 DNS 解析；
// - 同网段：目标落在本机某个已启用接口的直连网段内（IPv4 与 IPv6 都按接口地址的前缀长度判断），或是 IPv6 链路本地、
//   组播、IPv4 受限广播与组播地址时不发包（D61 实测：发往同网段其他设备会弹「本地网络」授权框）。默认网关本身放行。
//   回环接口与点对点接口（VPN 的 utun 等）不算直连网段。

import Darwin
import Foundation

public enum LatencyTargetPolicy {
    /// 本机一个接口的直连网段：地址与掩码，按网络字节序（IPv4 4 字节，IPv6 16 字节）。
    struct Prefix: Hashable, Sendable {
        var address: [UInt8]
        var mask: [UInt8]
    }

    /// 输入框里的值能否作为延迟目标（D102：提交时校验，不合法时保持上一个生效值）。
    public static func isValidHost(_ text: String) -> Bool {
        let host = text.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return false }
        if addressBytes(host) != nil { return true }
        var name = Substring(host)
        if name.hasSuffix(".") { name = name.dropLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        // 全是数字和点的不当主机名（如输入一半的 223.5.5）。
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// IP 字面量的字节（网络字节序）；不是字面量时为 nil。IPv6 的 %scope 忽略。
    static func addressBytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        let bare = String(text.split(separator: "%", maxSplits: 1).first ?? "")
        if inet_pton(AF_INET6, bare, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// 发往 `address` 会不会落到本机直连网段里的其他设备上。`gateways` 是当前默认网关（放行）。
    static func isLocalNetwork(_ address: String, prefixes: [Prefix], gateways: [String]) -> Bool {
        guard let bytes = addressBytes(address) else { return false }
        if gateways.contains(where: { addressBytes($0) == bytes }) { return false }
        if bytes.count == 4 {
            if bytes == [255, 255, 255, 255] || (bytes[0] & 0xf0) == 0xe0 { return true }  // 受限广播、组播
        } else {
            if bytes[0] == 0xff { return true }  // 组播
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }  // 链路本地
        }
        return prefixes.contains { prefix in
            prefix.address.count == bytes.count
                && zip(zip(prefix.address, prefix.mask), bytes).allSatisfy { pair, b in (pair.0 & pair.1) == (b & pair.1) }
        }
    }

    /// 本机已启用接口的直连网段（getifaddrs 的地址与掩码；不读字节计数）。
    static func onLinkPrefixes() -> [Prefix] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: Set<Prefix> = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = p {
            defer { p = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                let sa = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask
            else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                out.insert(Prefix(address: withUnsafeBytes(of: a) { Array($0) }, mask: withUnsafeBytes(of: m) { Array($0) }))
            case AF_INET6:
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let m = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                out.insert(Prefix(address: withUnsafeBytes(of: a) { Array($0) }, mask: withUnsafeBytes(of: m) { Array($0) }))
            default:
                continue
            }
        }
        // 掩码全 0 的条目（不应出现）会匹配所有地址，丢掉。
        return out.filter { $0.mask.contains { $0 != 0 } }
    }
}
