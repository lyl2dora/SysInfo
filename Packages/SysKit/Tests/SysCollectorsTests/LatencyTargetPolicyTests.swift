// 自定义延迟地址的格式校验与同网段拦截（D102，审计 A31）。

import Testing
@testable import SysCollectors

@Suite struct LatencyTargetPolicyTests {
    @Test func acceptsLiteralsAndHostNames() {
        for host in ["223.5.5.5", "2400:3200::1", "fe80::1%en0", "example.com", "dns.example.com.", "a-b.example", "localhost"] {
            #expect(LatencyTargetPolicy.isValidHost(host), "\(host)")
        }
    }

    /// 输入到一半的值不生效。
    @Test func rejectsPartialAndMalformedInput() {
        for host in ["", " ", "2", "22", "223.", "223.5.5", "223.5.5.", "-a.com", "a-.com", "a..com", "a b.com", "例子.com",
            String(repeating: "a", count: 64) + ".com"]
        {
            #expect(!LatencyTargetPolicy.isValidHost(host), "\(host)")
        }
    }

    private static let lan = LatencyTargetPolicy.Prefix(address: [192, 0, 2, 7], mask: [255, 255, 255, 0])
    private static let v6 = LatencyTargetPolicy.Prefix(
        address: [0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7],
        mask: [UInt8](repeating: 0xff, count: 8) + [UInt8](repeating: 0, count: 8))

    @Test func blocksSameSubnet() {
        let prefixes = [Self.lan, Self.v6]
        #expect(LatencyTargetPolicy.isLocalNetwork("192.0.2.20", prefixes: prefixes, gateways: ["192.0.2.1"]))
        #expect(LatencyTargetPolicy.isLocalNetwork("2001:db8:1::20", prefixes: prefixes, gateways: []))
        #expect(LatencyTargetPolicy.isLocalNetwork("fe80::2%en0", prefixes: [], gateways: []))
        #expect(LatencyTargetPolicy.isLocalNetwork("255.255.255.255", prefixes: [], gateways: []))
        #expect(LatencyTargetPolicy.isLocalNetwork("224.0.0.251", prefixes: [], gateways: []))
        #expect(LatencyTargetPolicy.isLocalNetwork("ff02::1", prefixes: [], gateways: []))
    }

    @Test func allowsGatewayAndRoutedNetworks() {
        let prefixes = [Self.lan, Self.v6]
        #expect(!LatencyTargetPolicy.isLocalNetwork("192.0.2.1", prefixes: prefixes, gateways: ["192.0.2.1"]))
        #expect(!LatencyTargetPolicy.isLocalNetwork("fe80::1%en0", prefixes: prefixes, gateways: ["fe80::1%en0"]))
        #expect(!LatencyTargetPolicy.isLocalNetwork("198.51.100.20", prefixes: prefixes, gateways: []))
        #expect(!LatencyTargetPolicy.isLocalNetwork("223.5.5.5", prefixes: prefixes, gateways: []))
        #expect(!LatencyTargetPolicy.isLocalNetwork("2001:db8:2::20", prefixes: prefixes, gateways: []))
    }

    /// 本机至少有一个已启用的直连网段，且不含回环。
    @Test(.tags(.hardware), .hardwareOnly) func readsOnLinkPrefixes() {
        let prefixes = LatencyTargetPolicy.onLinkPrefixes()
        #expect(!prefixes.isEmpty)
        #expect(!prefixes.contains { $0.address == [127, 0, 0, 1] })
    }
}
