// 设置的「网络」页（网络模块设计 §7，D41、D60–D62）。
//
// 按 D41 的模块页结构分节：菜单栏（网速、网络延迟）、采集、延迟（D61：默认关）、公网 IP（D62）、面板、历史。
// 延迟目标与公网 IP 服务是本 app 仅有的出站目标，同时列在「隐私」页（D22）。

import SwiftUI
import SysCollectors
import SysModel

struct NetworkSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let model: NetworkModel
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(MenuWidget.widgets(of: .network)) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("速率是接口字节（含协议头），开 VPN 时主接口取它下面的物理接口：隧道上只有内层流量，经系统代理的流量不经过隧道。任何地方都不把全部接口相加，虚拟机与 VPN 的流量会在多个接口上重复计数。")
                    HStack(spacing: 4) {
                        Text("排版和小标签对所有模块统一生效。")
                        Button("在「菜单栏」页设置") { openPage(.menuBar) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }

            Section("采集") {
                Picker("常驻采集间隔", selection: $settings.networkIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                Text("面板里的速率固定每秒一次；Wi-Fi 卡片只在面板可见时每 5 秒读一次，后台不读。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("开启延迟", isOn: $settings.latencyEnabled)
                if settings.latencyEnabled {
                    Toggle("默认网关", isOn: $settings.latencyGateway)
                    Toggle("自定义地址", isOn: $settings.latencyCustom)
                    if settings.latencyCustom {
                        LatencyHostField(settings: settings)
                    }
                    Picker("发包间隔", selection: $settings.latencyInterval) {
                        ForEach(AppSettings.latencyIntervals, id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds)
                        }
                    }
                }
            } header: {
                Text("延迟")
            } footer: {
                Text("开启后会向所选目标发送 ICMP 回显请求（ping），只在网络面板可见或「网络延迟」widget 打开时发包。测默认网关不需要任何授权，但只反映局域网；1.1.1.1、8.8.8.8 这类常见地址可能被路由器或代理就近代答，测不到真实外网延迟，默认填的 223.5.5.5 在本机网络里实测是真实的。地址按回车或离开输入框后才生效。与本机同网段的其他设备不发包（向它们发包需要「本地网络」授权），填了也只显示「同网段，不测」；经路由转发的其他网段可以测。")
                    .font(.callout)
            }

            Section {
                TextField("查询服务", text: $settings.publicIPService, prompt: Text("https://…（留空则第一次查询时再填）"))
            } header: {
                Text("公网 IP")
            } footer: {
                Text("面板里点「查询」时才向这个地址发一次 HTTPS 请求，取响应里的第一个 IP 地址；结果只显示、不保存，不查询归属地。开着代理时结果是代理出口的地址。")
                    .font(.callout)
            }

            Section("面板") {
                Picker("图表默认跨度", selection: $settings.networkChartSpan) {
                    ForEach(ChartSpan.allCases) { span in
                        Text(HistoryChart.title(span)).tag(span)
                    }
                }
                Toggle("虚拟接口列表只看活跃", isOn: $settings.networkVirtualActiveOnly)
            }

            Section {
                Toggle("记录网络历史", isOn: $settings.historyNetworkEnabled)
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("面板关闭时也在后台每 60 秒记录一次主接口与每个物理接口的流量（计数是累计值，不会漏记），面板据此统计今日 / 本月流量；开启延迟时另记 RTT 与丢包。每应用的网络流量留给 P1。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

/// 自定义延迟地址（D102）：按回车或离开输入框才生效，生效前校验格式；不合法时提示，保持上一个生效值。
private struct LatencyHostField: View {
    @Bindable var settings: AppSettings
    @State private var draft = ""
    @State private var rejected: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("地址", text: $draft, prompt: Text("IP 或主机名"))
                .focused($focused)
                .onSubmit(commit)
            if let rejected {
                Text("「\(rejected)」不是有效的 IP 地址或主机名，仍在测「\(settings.latencyHost)」。")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { draft = settings.latencyHost }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: settings.latencyHost) { _, host in
            draft = host
            rejected = nil
        }
    }

    private func commit() {
        let host = draft.trimmingCharacters(in: .whitespaces)
        guard host != settings.latencyHost else {
            rejected = nil
            return
        }
        guard LatencyTargetPolicy.isValidHost(host) else {
            rejected = host
            return
        }
        rejected = nil
        settings.latencyHost = host
    }
}
