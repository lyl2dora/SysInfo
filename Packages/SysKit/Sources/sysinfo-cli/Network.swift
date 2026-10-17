// sysinfo-cli network（网络模块设计 §7）。
//
// - 清单：主接口、VPN、各接口的类型、物理判定、链路速率；默认不打印本机地址、网关与 DNS（跨机对照的输出会被贴进文档），
//   --addresses 才打印；
// - 逐次打印主接口、物理合计与每个接口的入 / 出速率；--diag 另打印原始计数；--wifi 读一次 CoreWLAN；
// - --latency 每次采样向「gateway」或指定地址各发一个 ICMP 探测包（只在手动运行时发包，D61）。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func rateText(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond.map { decimalBytes($0) + "/s" } ?? "—"
    }

    static func kindName(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .ethernet: "以太网"
        case .wifi: "Wi-Fi"
        case .bridge: "网桥"
        case .tunnel: "隧道"
        case .virtualMachine: "虚拟机"
        case .awdl: "AWDL"
        case .other: "其他"
        }
    }

    static func runNetwork(
        interval: Double, count: Int, diagnostics: Bool, wifi: Bool, latency: String?, addresses: Bool, json: Bool
    ) -> Int32 {
        let io = NetworkIOCollector()
        let wifiCollector = WiFiCollector()
        let latencyCollector = LatencyCollector()
        var collectors: [any Collector] = [io]
        if wifi { collectors.append(wifiCollector) }
        if let latency {
            latencyCollector.setTargets(
                .init(gateway: latency == "gateway", custom: latency == "gateway" ? nil : latency))
            collectors.append(latencyCollector)
        }
        for collector in collectors {
            let result = collector.selfTest()
            for check in result.checks where !check.passed || !json {
                let mark = check.passed ? "✓" : check.severity == .advisory ? "!" : "✗"
                printError("    \(mark) \(check.name)：\(check.detail)")
            }
        }
        let state = NetworkInventory.shared.snapshot()
        let encoder = makeEncoder()
        if json {
            var shown = state
            if !addresses {
                shown.interfaces = shown.interfaces.map { var i = $0; i.ipv4 = []; i.ipv6 = []; return i }
                shown.gatewayIPv4 = nil
                shown.gatewayIPv6 = nil
                shown.dnsServers = []
            }
            struct Header: Encodable { var machine: MachineInfo; var state: NetworkState }
            if let data = try? encoder.encode(Header(machine: .current, state: shown)) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            print(machineLine())
            print(
                "主接口 \(state.primary ?? "（离线）") · 默认路由 \(state.defaultRouteInterface ?? "—") · VPN \(state.vpnActive ? "是" : "否")"
                    + " · 代理 \(state.proxyEnabled ? "开" : "关") · 接口 \(state.interfaces.count) 个（物理 \(state.physical.count)）")
            if addresses {
                print("  网关 \(state.gatewayIPv4 ?? "—") / \(state.gatewayIPv6 ?? "—") · DNS \(state.dnsServers.joined(separator: ", "))")
            }
            for interface in state.interfaces {
                var parts = [
                    interface.name, kindName(interface.kind), interface.isPhysical ? "物理" : "虚拟",
                    interface.displayName ?? "—",
                ]
                if let speed = interface.linkSpeed { parts.append(String(format: "链路 %.0f Mb/s", speed / 1e6)) }
                parts.append("控制器 \(interface.controllerClass ?? "—")")
                parts.append("SC \(interface.scType ?? "—")")
                if addresses {
                    parts.append((interface.ipv4 + interface.ipv6).joined(separator: " "))
                } else {
                    parts.append("地址 v4×\(interface.ipv4.count) v6×\(interface.ipv6.count)")
                }
                print("  " + parts.joined(separator: " · "))
            }
        }
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 0...count {
            if index > 0 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let now = SampleTime.now()
            var costs: [String] = []
            var samples: [Sample] = []
            for collector in collectors {
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                samples += collector.sample(at: now).samples
                costs.append(
                    String(format: "%@ %.3f ms", collector.id.rawValue, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6))
            }
            guard index > 0 else { continue }  // 第 0 次只建立基线、发出第一个探测包
            if json {
                struct Record: Encodable { var index: Int; var samples: [Sample] }
                if let data = try? encoder.encode(Record(index: index, samples: samples)) { print(String(decoding: data, as: UTF8.self)) }
                continue
            }
            let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            func describe(_ id: MetricID) -> String {
                guard let sample = byID[id] else { return "—" }
                if let value = sample.value { return rateText(value) }
                if case .unavailable(let reason) = sample.quality { return "不可用(\(reason))" }
                return "—"
            }
            print("#\(index)  CPU：\(costs.joined(separator: "，"))")
            print("  主接口 ↓ \(describe(.networkPrimaryIn)) ↑ \(describe(.networkPrimaryOut)) · 物理合计 ↓ \(describe(.networkPhysicalIn)) ↑ \(describe(.networkPhysicalOut))")
            let counters = io.latestCounters
            for interface in io.lastState.interfaces {
                var line = "    \(interface.name.padding(toLength: 10, withPad: " ", startingAt: 0)) ↓ \(describe(.network(interface, .in))) ↑ \(describe(.network(interface, .out)))"
                if diagnostics, let c = counters[interface.name] {
                    line += " · 包 \(c.packetsIn)/\(c.packetsOut) 错误 \(c.errorsIn)/\(c.errorsOut) 丢包 \(c.dropsIn) 组播 \(c.multicastIn)/\(c.multicastOut) 冲突 \(c.collisions)"
                }
                print(line)
            }
            if wifi {
                let info = wifiCollector.latestInfo
                func value(_ id: MetricID, _ format: String) -> String { byID[id]?.value.map { String(format: format, $0) } ?? "—" }
                print(
                    "  Wi-Fi \(info?.interfaceName ?? "—") · RSSI \(value(.networkWiFiRSSI, "%.0f dBm")) · 噪声 \(value(.networkWiFiNoise, "%.0f dBm"))"
                        + " · SNR \(value(.networkWiFiSNR, "%.0f dB")) · 发送 \(byID[.networkWiFiTxRate]?.value.map { String(format: "%.0f Mb/s", $0 / 1e6) } ?? "—")"
                        + " · 信道 \(info?.channel.map(String.init) ?? "—") \(info?.bandGHz.map { "\($0) GHz" } ?? "") \(info?.widthMHz.map { "\($0) MHz" } ?? "")"
                        + " · \(info?.phyMode ?? "—") · 发送功率原值 \(info?.transmitPowerRaw.map { "\($0) mW" } ?? "—")")
            }
            if latency != nil {
                for target in MetricID.LatencyTarget.allCases {
                    guard let rtt = byID[.networkLatencyRTT(target)] ?? byID[.networkLatencyLoss(target)] else { continue }
                    let rttText: String =
                        if let v = byID[.networkLatencyRTT(target)]?.value { String(format: "%.2f ms", v * 1000) }
                        else if case .unavailable(let reason)? = byID[.networkLatencyRTT(target)]?.quality { "不可用(\(reason))" }
                        else { "等待回包" }
                    let loss = byID[.networkLatencyLoss(target)]?.value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
                    _ = rtt
                    print("  延迟 \(target.rawValue) RTT \(rttText) · 丢包 \(loss)")
                }
            }
        }
        return 0
    }
}
