// 诊断页的网络部分（网络模块设计 §7，D60 N9）：
// - 每个接口的分类依据（控制器类、SC 类型、IFMIB 类型、链路速率来源）与原始 IFMIB 计数；
//   `IOUserEthernet` 接口（虚拟机网卡）的丢包数是垃圾值（两台实测 10¹³–10¹⁶），标「不可靠」；
// - SCDynamicStore 的判定：默认路由接口、主接口、VPN；
// - NWPath（展开「NWPath」时才启动 NWPathMonitor，收起即停）；
// - CoreWLAN 原值：只显示面板最近一次读到的值，诊断页不另读（D10：只在面板打开时读）。
// 地址、网关、DNS 不在这里显示（诊断页常被截图分享）。

import Network
import SwiftUI
import SysCollectors
import SysModel

struct NetworkDiagnosticsSection: View {
    let store: MetricStore
    let services: AppServices

    @State private var pathExpanded = false
    @State private var path = NWPathModel()

    var body: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        interfacesSection
        routingSection
    }

    private var interfacesSection: some View {
        Section("网络数据源") {
            let state = services.networkModel.state
            let counters = services.network.io?.latestCounters ?? [:]
            LabeledContent("接口清单") {
                Text("\(state.interfaces.count) 个（物理 \(state.physical.count)）· 第 \(state.generation) 代")
            }
            ForEach(state.interfaces) { interface in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let c = counters[interface.name] {
                            Text("包 \(c.packetsIn) / \(c.packetsOut) · 错误 \(c.errorsIn) / \(c.errorsOut)")
                            Text(
                                "丢包 \(interface.controllerClass == "IOUserEthernetController" ? String(localized: "\(c.dropsIn)（不可靠）") : "\(c.dropsIn)") · 组播 \(c.multicastIn) / \(c.multicastOut) · 冲突 \(c.collisions)"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        } else {
                            Text("—")
                        }
                    }
                } label: {
                    Text("\(interface.name) · \(NetworkText.kind(interface.kind)) · \(interface.isPhysical ? String(localized: "物理") : String(localized: "虚拟"))")
                    Text(
                        "控制器 \(interface.controllerClass ?? "—") · SC \(interface.scType ?? "—") · ifType \(interface.ifType) · 速率 \(interface.linkSpeed.map(NetworkText.linkSpeed) ?? (interface.kind == .wifi ? String(localized: "见 CoreWLAN") : "—"))"
                    )
                }
            }
            Text("物理接口：有 IOKit 控制器、不是虚拟机网卡或 USB 设备模式接口，且链路活跃或有地址；雷电 IP 端口由 Thunderbolt Bridge 代表。字节计数只用 IFMIB（64 位）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var routingSection: some View {
        Section("路由与 Wi-Fi") {
            let state = services.networkModel.state
            LabeledContent("默认路由接口", value: state.defaultRouteInterface ?? "—")
            LabeledContent("主接口（隧道时取下层物理接口）", value: state.primary ?? String(localized: "离线"))
            LabeledContent("VPN", value: state.vpnActive ? String(localized: "是") : String(localized: "否"))
            LabeledContent("代理", value: state.proxyEnabled ? String(localized: "开启") : String(localized: "关闭"))
            if let info = services.network.wifi?.latestInfo {
                LabeledContent("CoreWLAN（面板最近一次读取）") {
                    Text(
                        "\(info.interfaceName) · 电源 \(info.powerOn ? "开" : "关") · 信道 \(info.channel.map(String.init) ?? "—") · \(info.phyMode ?? "—") · 发送功率原值 \(info.transmitPowerRaw.map { "\($0) mW" } ?? "—")（不可靠）"
                    )
                }
            } else {
                LabeledContent("CoreWLAN", value: String(localized: "面板 Wi-Fi 卡片可见时才读"))
            }
            if let status = services.network.latency?.status, !status.isEmpty {
                ForEach(MetricID.LatencyTarget.allCases, id: \.self) { target in
                    if let s = status[target] {
                        LabeledContent("延迟探测 \(target.rawValue)", value: "已发 \(s.sent) · 收到 \(s.received)")
                    }
                }
            }
            DisclosureGroup("NWPath", isExpanded: $pathExpanded) {
                if let snapshot = path.snapshot {
                    LabeledContent("状态", value: snapshot.status)
                    LabeledContent("链路质量", value: snapshot.linkQuality)
                    LabeledContent("昂贵 / 受限", value: "\(snapshot.expensive ? "是" : "否") / \(snapshot.constrained ? "是" : "否")")
                    LabeledContent("可用接口", value: snapshot.interfaces)
                } else {
                    Text("等待 NWPathMonitor…").foregroundStyle(.secondary)
                }
            }
            .onChange(of: pathExpanded) { _, expanded in expanded ? path.start() : path.stop() }
            .onDisappear { path.stop() }
        }
    }
}

/// NWPathMonitor 的包装：只在展开时运行（事件驱动，不轮询）。
@Observable
final class NWPathModel {
    struct Snapshot: Equatable {
        var status: String
        var linkQuality: String
        var expensive: Bool
        var constrained: Bool
        var interfaces: String
    }

    private(set) var snapshot: Snapshot?
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Snapshot(
                status: "\(path.status)", linkQuality: "\(path.linkQuality)", expensive: path.isExpensive,
                constrained: path.isConstrained, interfaces: path.availableInterfaces.map(\.name).joined(separator: ", "))
            DispatchQueue.main.async { self?.snapshot = snapshot }
        }
        monitor.start(queue: DispatchQueue(label: "zone.lyl.sysinfo.diagnostics.nwpath", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
