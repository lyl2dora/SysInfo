// 网络模块（网络模块设计 §4、§5，D60、D61）：接口分类、速率差分与复位、MetricID 解析、ICMP 回包解析；
// 硬件测试读真实机器（`make test-hw`），断言只用运行时读到的值，不写死任何机型的接口名或数量（D20）。

import Darwin
import Foundation
import SysModel
import Testing
@testable import SysCollectors

@Suite struct NetworkClassificationTests {
    private func raw(
        _ name: String, ifType: Int32 = IFT_ETHER, flags: Int32 = IFF_UP | IFF_RUNNING, media: (active: Bool, wifi: Bool)? = (true, false),
        bytesIn: UInt64 = 0, ipv4: [String] = [], ipv6: [String] = [], scType: String? = nil, controller: String? = nil
    ) -> NetworkInventory.RawInterface {
        NetworkInventory.RawInterface(
            name: name, index: 1, ifType: UInt8(ifType), flags: UInt32(flags), hasMedia: media != nil,
            mediaActive: media?.active ?? false, mediaIsWiFi: media?.wifi ?? false, bytesIn: bytesIn, ipv4: ipv4, ipv6Global: ipv6,
            scType: scType, displayName: nil, hasIOKit: controller != nil, controllerClass: controller)
    }

    @Test func builtInEthernetWithDifferentDriversIsPhysical() {
        // 两台机器的内置 10 GbE 驱动类不同（2026-10-17 实测），都要判成物理以太网。
        for controller in ["AppleSkywalkAVBLegacyEthernet", "AppleEthernetAquantiaAqtion113"] {
            let r = NetworkInventory.classify(raw("en0", scType: "Ethernet", controller: controller))
            #expect(r?.kind == .ethernet)
            #expect(r?.physical == true)
        }
    }

    @Test func wifiIsPhysical() {
        let r = NetworkInventory.classify(raw("en1", media: (true, true), scType: "IEEE80211", controller: "IO80211Controller"))
        #expect(r?.kind == .wifi)
        #expect(r?.physical == true)
    }

    @Test func excludedInterfaces() {
        // Mac 作 USB 设备时的接口、雷电 IP 端口（Thunderbolt Bridge 成员）、回环、gif/stf 不进清单。
        #expect(NetworkInventory.classify(raw("en4", scType: "Ethernet", controller: "AppleUSBDeviceNCM11Data")) == nil)
        #expect(NetworkInventory.classify(raw("en2", scType: "Ethernet", controller: "AppleThunderboltIPPort")) == nil)
        #expect(NetworkInventory.classify(raw("lo0", ifType: IFT_LOOP, flags: IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == nil)
        #expect(NetworkInventory.classify(raw("gif0", ifType: IFT_GIF, flags: IFF_UP | IFF_POINTOPOINT, media: nil)) == nil)
    }

    @Test func inactivePhysicalIsDropped() {
        #expect(NetworkInventory.classify(raw("en0", media: (false, false), scType: "Ethernet", controller: "X")) == nil)
        // 链路 inactive 但有地址：仍算活跃。
        #expect(NetworkInventory.classify(raw("en0", media: (false, false), ipv4: ["192.0.2.2"], scType: "Ethernet", controller: "X")) != nil)
    }

    @Test func virtualKinds() {
        #expect(NetworkInventory.classify(raw("vmenet0", scType: nil, controller: "IOUserEthernetController"))?.kind == .virtualMachine)
        #expect(NetworkInventory.classify(raw("bridge100", ifType: IFT_BRIDGE, ipv4: ["192.0.2.64"]))?.kind == .virtualMachine)
        #expect(NetworkInventory.classify(raw("bridge0", ifType: IFT_BRIDGE, ipv4: ["169.254.1.1"], scType: "Bridge"))?.kind == .bridge)
        #expect(NetworkInventory.classify(raw("bridge0", ifType: IFT_BRIDGE, ipv4: ["169.254.1.1"], scType: "Bridge"))?.physical == true)
        let tunnel = NetworkInventory.classify(
            raw("utun9", ifType: IFT_OTHER, flags: IFF_UP | IFF_RUNNING | IFF_POINTOPOINT, media: nil, ipv4: ["198.18.0.1"]))
        #expect(tunnel?.kind == .tunnel)
        #expect(tunnel?.physical == false)
        #expect(NetworkInventory.classify(raw("awdl0", media: (true, true)))?.kind == .awdl)
    }

    @Test func idleTunnelWithoutAddressOrInboundIsDropped() {
        // 系统常驻的空闲 utun：只有出向的零星字节、没有可路由地址。
        #expect(
            NetworkInventory.classify(raw("utun0", ifType: IFT_OTHER, flags: IFF_UP | IFF_RUNNING | IFF_POINTOPOINT, media: nil)) == nil)
        #expect(
            NetworkInventory.classify(
                raw("utun4", ifType: IFT_OTHER, flags: IFF_UP | IFF_RUNNING | IFF_POINTOPOINT, media: nil, bytesIn: 12_288)) != nil)
    }

    @Test func tunnelNames() {
        #expect(NetworkInventory.isTunnelName("utun9"))
        #expect(NetworkInventory.isTunnelName("ipsec0"))
        #expect(NetworkInventory.isTunnelName("ppp0"))
        #expect(!NetworkInventory.isTunnelName("en0"))
        #expect(!NetworkInventory.isTunnelName("bridge100"))
    }
}

@Suite struct NetworkRateTests {
    private func counters(_ bytesIn: UInt64, _ bytesOut: UInt64) -> NetworkCounters {
        NetworkCounters(
            bytesIn: bytesIn, bytesOut: bytesOut, packetsIn: 0, packetsOut: 0, errorsIn: 0, errorsOut: 0, dropsIn: 0, multicastIn: 0,
            multicastOut: 0, collisions: 0)
    }

    @Test func ratesPerSecond() {
        let r = NetworkIOCollector.rates(previous: counters(1_000, 2_000), current: counters(3_000, 2_500), elapsedNanos: 2_000_000_000)
        #expect(r.in == 1_000)
        #expect(r.out == 250)
    }

    @Test func negativeDeltaIsResetNotZero() {
        // 计数回退按复位处理：给 nil（这一段不可用），不钳为 0（CLAUDE.md）。
        let r = NetworkIOCollector.rates(previous: counters(5_000, 5_000), current: counters(100, 6_000), elapsedNanos: 1_000_000_000)
        #expect(r.in == nil)
        #expect(r.out == 1_000)
    }

    @Test func largeCountersDoNotWrap() {
        // 64 位计数：超过 2³² 的值照常差分（IFLIST2 的 32 位截断不会出现）。
        let base: UInt64 = 1 << 40
        let r = NetworkIOCollector.rates(previous: counters(base, 0), current: counters(base + 1_250_000_000, 0), elapsedNanos: 1_000_000_000)
        #expect(r.in == 1_250_000_000)
    }

    @Test func zeroElapsedGivesNothing() {
        let r = NetworkIOCollector.rates(previous: counters(1, 1), current: counters(2, 2), elapsedNanos: 0)
        #expect(r.in == nil && r.out == nil)
    }
}

@Suite struct NetworkMetricIDTests {
    @Test func interfaceMetricRoundTrip() {
        let physical = MetricID.networkInterface("en0", .in)
        #expect(physical.rawValue == "net.if.en0.in")
        #expect(physical.networkInterfaceMetric?.name == "en0")
        #expect(physical.networkInterfaceMetric?.direction == .in)
        #expect(physical.networkInterfaceMetric?.physical == true)
        let virtual = MetricID.networkVirtualInterface("bridge100", .out)
        #expect(virtual.rawValue == "net.vif.bridge100.out")
        #expect(virtual.networkInterfaceMetric?.physical == false)
        #expect(MetricID.networkPrimaryIn.networkInterfaceMetric == nil)
        #expect(MetricID("net.if.en0").networkInterfaceMetric == nil)
        #expect(MetricID("net.if.en0.sideways").networkInterfaceMetric == nil)
    }

    @Test func latencyMetric() {
        #expect(MetricID.networkLatencyRTT(.gateway).rawValue == "net.latency.gateway.rtt")
        #expect(MetricID.networkLatencyLoss(.custom).networkLatencyMetric?.target == .custom)
        #expect(MetricID.networkLatencyLoss(.custom).networkLatencyMetric?.isRTT == false)
        #expect(MetricID.networkPrimaryOut.networkLatencyMetric == nil)
    }
}

@Suite struct LatencyParsingTests {
    @Test func ipv4ReplyWithHeader() {
        // IPv4 DGRAM 套接字收到的数据带 20 字节 IP 头。
        var data = [UInt8](repeating: 0, count: 20 + 16)
        data[0] = 0x45
        data[20] = 0  // echo reply
        data[24] = 0x12
        data[25] = 0x34
        data[26] = 0x00
        data[27] = 0x07
        let r = LatencyCollector.parseReply(data, family: AF_INET)
        #expect(r?.type == 0)
        #expect(r?.identifier == 0x1234)
        #expect(r?.seq == 7)
    }

    @Test func ipv4ReplyWithoutHeader() {
        let data: [UInt8] = [0, 0, 0, 0, 0xab, 0xcd, 0, 1]
        #expect(LatencyCollector.parseReply(data, family: AF_INET)?.identifier == 0xabcd)
    }

    @Test func ipv6ReplyAndTruncated() {
        let data: [UInt8] = [129, 0, 0, 0, 0x43, 0x21, 0x01, 0x00]
        #expect(LatencyCollector.parseReply(data, family: AF_INET6)?.type == 129)
        #expect(LatencyCollector.parseReply(data, family: AF_INET6)?.seq == 256)
        #expect(LatencyCollector.parseReply([129, 0, 0], family: AF_INET6) == nil)
    }

    @Test func checksumMatchesKnownPacket() {
        // echo request，id 0x1234、seq 0、其余为 0：校验和 = ~(0x0800 + 0x1234)。
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[4] = 0x12
        packet[5] = 0x34
        #expect(LatencyCollector.checksum(packet) == ~UInt16(0x0800 + 0x1234))
    }

    @Test func sockaddrLiterals() {
        #expect(LatencyCollector.withSockaddr("223.5.5.5", family: AF_INET) { _, length in length } != nil)
        #expect(LatencyCollector.withSockaddr("223.5.5.5", family: AF_INET6) { _, _ in 0 } == nil)
        #expect(LatencyCollector.withSockaddr("2400:3200::1", family: AF_INET6) { _, _ in 0 } != nil)
        #expect(LatencyCollector.withSockaddr("example.com", family: AF_INET) { _, _ in 0 } == nil)
    }
}

@Suite(.tags(.hardware), .hardwareOnly)
struct NetworkHardwareTests {
    @Test func inventoryAndRates() throws {
        let io = NetworkIOCollector(inventory: NetworkInventory())
        let result = io.selfTest()
        #expect(result.isUsable, "\(result.checks)")
        let first = SampleTime.now()
        _ = io.sample(at: first)
        usleep(1_100_000)
        let output = io.sample(at: SampleTime.now())
        let state = io.lastState
        // 有物理接口的机器：每个物理接口都有入 / 出两个样本，数值非负。
        for interface in state.physical {
            for direction in MetricID.NetworkDirection.allCases {
                let sample = output.samples.first { $0.id == .network(interface, direction) }
                #expect(sample != nil, "\(interface.name) \(direction)")
                if let value = sample?.value { #expect(value >= 0) }
            }
        }
        if let primary = state.primary {
            #expect(state.interface(primary)?.isPhysical == true, "主接口应为物理接口（D60）")
            #expect(output.samples.contains { $0.id == .networkPrimaryIn && $0.value != nil })
        }
        // 虚拟接口不能出现在物理前缀下。
        for interface in state.virtual {
            #expect(!output.samples.contains { $0.id == .networkInterface(interface.name, .in) })
        }
    }

    @Test func gatewayLatencyWhenAvailable() throws {
        let inventory = NetworkInventory()
        guard inventory.snapshot().gatewayIPv4 != nil else { return }
        let latency = LatencyCollector(inventory: inventory)
        latency.setTargets(.init(gateway: true, custom: nil))
        #expect(latency.selfTest().isUsable)
        _ = latency.sample(at: SampleTime.now())
        usleep(1_000_000)
        let samples = latency.sample(at: SampleTime.now()).samples
        let rtt = samples.first { $0.id == .networkLatencyRTT(.gateway) }
        #expect(rtt?.value.map { $0 > 0 && $0 < 1 } ?? true)
    }
}
