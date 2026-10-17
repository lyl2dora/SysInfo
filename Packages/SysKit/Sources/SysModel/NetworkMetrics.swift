// 网络模块的数据模型（网络模块设计 §4，D60–D62）。指标命名一旦发布就不改。
//
// - 接口用 BSD 名作键（`en0`、`utun9`）：不是设备唯一标识；
// - 速率是接口字节（含协议头）÷ 秒，B/s；Wi-Fi 发送速率 bit/s；RTT 秒；比例 0…1；
// - 物理接口与虚拟接口分两个前缀（`net.if.`、`net.vif.`）：历史只记物理接口，面板按前缀分组（D60）。

extension MetricID {
    private static let physicalPrefix = "net.if."
    private static let virtualPrefix = "net.vif."

    /// 方向：入（下载）或出（上传）。
    public enum NetworkDirection: String, Sendable, CaseIterable {
        case `in`
        case out
    }

    /// 物理接口的速率，B/s。
    public static func networkInterface(_ name: String, _ direction: NetworkDirection) -> MetricID {
        MetricID("\(physicalPrefix)\(name).\(direction.rawValue)")
    }

    /// 虚拟接口（隧道、虚拟机网卡与网桥、awdl）的速率，B/s。
    public static func networkVirtualInterface(_ name: String, _ direction: NetworkDirection) -> MetricID {
        MetricID("\(virtualPrefix)\(name).\(direction.rawValue)")
    }

    /// 某个接口的速率指标：物理用 `net.if.`，虚拟用 `net.vif.`。
    public static func network(_ interface: NetworkInterface, _ direction: NetworkDirection) -> MetricID {
        interface.isPhysical ? networkInterface(interface.name, direction) : networkVirtualInterface(interface.name, direction)
    }

    /// 主接口（隧道时取下层物理接口，D60）的速率，B/s。
    public static let networkPrimaryIn: MetricID = "net.primary.in"
    public static let networkPrimaryOut: MetricID = "net.primary.out"
    /// 活跃物理接口合计，B/s（D60：只加物理接口，彼此不重复计数）。
    public static let networkPhysicalIn: MetricID = "net.physical.in"
    public static let networkPhysicalOut: MetricID = "net.physical.out"

    public static func networkPrimary(_ direction: NetworkDirection) -> MetricID {
        direction == .in ? networkPrimaryIn : networkPrimaryOut
    }

    public static func networkPhysical(_ direction: NetworkDirection) -> MetricID {
        direction == .in ? networkPhysicalIn : networkPhysicalOut
    }

    /// Wi-Fi 信号强度，dBm（CoreWLAN，D60 N5）。
    public static let networkWiFiRSSI: MetricID = "net.wifi.rssi"
    /// Wi-Fi 噪声，dBm。
    public static let networkWiFiNoise: MetricID = "net.wifi.noise"
    /// 信噪比，dB（RSSI − 噪声）。
    public static let networkWiFiSNR: MetricID = "net.wifi.snr"
    /// Wi-Fi 发送速率，bit/s。
    public static let networkWiFiTxRate: MetricID = "net.wifi.txRate"

    /// 延迟目标（D61）。
    public enum LatencyTarget: String, Sendable, CaseIterable, Codable {
        case gateway
        case custom
    }

    /// 最近一个间隔里收到的回包 RTT 均值，s。
    public static func networkLatencyRTT(_ target: LatencyTarget) -> MetricID {
        MetricID("net.latency.\(target.rawValue).rtt")
    }

    /// 最近 10 个探测包的丢失比例，0…1。
    public static func networkLatencyLoss(_ target: LatencyTarget) -> MetricID {
        MetricID("net.latency.\(target.rawValue).loss")
    }

    /// 若是每接口速率，返回接口名、方向与是否物理接口。
    public var networkInterfaceMetric: (name: String, direction: NetworkDirection, physical: Bool)? {
        let physical: Bool
        let rest: Substring
        if rawValue.hasPrefix(Self.physicalPrefix) {
            physical = true
            rest = rawValue.dropFirst(Self.physicalPrefix.count)
        } else if rawValue.hasPrefix(Self.virtualPrefix) {
            physical = false
            rest = rawValue.dropFirst(Self.virtualPrefix.count)
        } else {
            return nil
        }
        guard let dot = rest.lastIndex(of: "."), dot > rest.startIndex,
            let direction = NetworkDirection(rawValue: String(rest[rest.index(after: dot)...]))
        else { return nil }
        return (String(rest[..<dot]), direction, physical)
    }

    /// 若是延迟指标，返回目标与是否 RTT（否则为丢包率）。
    public var networkLatencyMetric: (target: LatencyTarget, isRTT: Bool)? {
        for target in LatencyTarget.allCases {
            if self == Self.networkLatencyRTT(target) { return (target, true) }
            if self == Self.networkLatencyLoss(target) { return (target, false) }
        }
        return nil
    }
}

extension UnavailableReason {
    /// 没有主接口（离线）。
    public static func offline(_ detail: String? = nil) -> Self { Self(code: "offline", detail: detail) }
    /// Wi-Fi 未开启或未关联。
    public static func notAssociated(_ detail: String? = nil) -> Self { Self(code: "notAssociated", detail: detail) }
    /// 这个间隔里探测包全部没有回音。
    public static func timeout(_ detail: String? = nil) -> Self { Self(code: "timeout", detail: detail) }
    /// 目标未设置或解析不出地址。
    public static func noTarget(_ detail: String? = nil) -> Self { Self(code: "noTarget", detail: detail) }
}

/// 接口类型（D60：按控制器与 SC 类型在运行时判断，不按名字写死）。
public enum NetworkInterfaceKind: String, CaseIterable, Hashable, Codable, Sendable {
    case ethernet
    case wifi
    /// SC 类型为 Bridge 的网桥（Thunderbolt Bridge）。
    case bridge
    /// utun、ipsec、ppp 等点对点隧道。
    case tunnel
    /// 虚拟机网卡（`IOUserEthernetController`）与虚拟机网桥（bridge1xx）。
    case virtualMachine
    /// AirDrop / 低延迟 Wi-Fi（awdl0、llw0）。
    case awdl
    case other
}

/// 一个网络接口（清单重建的结果，不随 tick 变化）。
public struct NetworkInterface: Hashable, Codable, Sendable, Identifiable {
    /// BSD 名。
    public var name: String
    /// if_index：只用于读 IFMIB，变化时重建差分基线。
    public var index: UInt32
    public var kind: NetworkInterfaceKind
    /// SCNetworkInterface 的本地化名（「以太网」「Wi-Fi」「雷雳网桥」）；虚拟接口通常没有。
    public var displayName: String?
    /// D60 的物理接口判定。
    public var isPhysical: Bool
    /// 链路 active 或有地址。
    public var isActive: Bool
    /// 链路速率，bit/s：以太网读 IOKit `IOLinkSpeed`；Wi-Fi 为 nil（发送速率由 `network.wifi` 给出）。
    public var linkSpeed: Double?
    /// IOKit 控制器类（诊断页）。
    public var controllerClass: String?
    /// SCNetworkInterface 类型（诊断页）。
    public var scType: String?
    /// IFMIB 的 ifi_type（诊断页）。
    public var ifType: UInt8
    /// 本机地址：只在面板与 CLI 显示，不写日志、不进历史。
    public var ipv4: [String]
    public var ipv6: [String]

    public var id: String { name }

    public init(
        name: String, index: UInt32, kind: NetworkInterfaceKind, displayName: String?, isPhysical: Bool, isActive: Bool,
        linkSpeed: Double?, controllerClass: String?, scType: String?, ifType: UInt8, ipv4: [String], ipv6: [String]
    ) {
        self.name = name
        self.index = index
        self.kind = kind
        self.displayName = displayName
        self.isPhysical = isPhysical
        self.isActive = isActive
        self.linkSpeed = linkSpeed
        self.controllerClass = controllerClass
        self.scType = scType
        self.ifType = ifType
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

/// 网络的结构状态（`NetworkInventory` 在变更通知时重建）。
public struct NetworkState: Hashable, Codable, Sendable {
    /// 进清单的接口：物理在前（按 index），虚拟在后。
    public var interfaces: [NetworkInterface]
    /// 主接口（D60：默认路由是隧道时取下层物理接口）；离线时为 nil。
    public var primary: String?
    /// SCDynamicStore 的 `PrimaryInterface` 原值（诊断页）。
    public var defaultRouteInterface: String?
    public var vpnActive: Bool
    /// 主接口所在服务的网关。
    public var gatewayIPv4: String?
    public var gatewayIPv6: String?
    /// `State:/Network/Global/DNS` 的服务器（反映 VPN 解析器）。
    public var dnsServers: [String]
    /// HTTP / HTTPS / SOCKS / 自动代理任一开启。
    public var proxyEnabled: Bool
    /// 每次清单内容变化加一。
    public var generation: UInt64

    public init(
        interfaces: [NetworkInterface], primary: String?, defaultRouteInterface: String?, vpnActive: Bool,
        gatewayIPv4: String?, gatewayIPv6: String?, dnsServers: [String], proxyEnabled: Bool, generation: UInt64
    ) {
        self.interfaces = interfaces
        self.primary = primary
        self.defaultRouteInterface = defaultRouteInterface
        self.vpnActive = vpnActive
        self.gatewayIPv4 = gatewayIPv4
        self.gatewayIPv6 = gatewayIPv6
        self.dnsServers = dnsServers
        self.proxyEnabled = proxyEnabled
        self.generation = generation
    }

    public static let empty = NetworkState(
        interfaces: [], primary: nil, defaultRouteInterface: nil, vpnActive: false, gatewayIPv4: nil, gatewayIPv6: nil,
        dnsServers: [], proxyEnabled: false, generation: 0)

    public func interface(_ name: String) -> NetworkInterface? { interfaces.first { $0.name == name } }

    public var primaryInterface: NetworkInterface? { primary.flatMap(interface) }

    public var physical: [NetworkInterface] { interfaces.filter(\.isPhysical) }
    public var virtual: [NetworkInterface] { interfaces.filter { !$0.isPhysical } }

    /// 活跃的 Wi-Fi 接口（面板据此决定是否显示 Wi-Fi 卡片）。
    public var activeWiFi: NetworkInterface? { interfaces.first { $0.kind == .wifi && $0.isActive } }
}

/// Wi-Fi 的非数值信息（`network.wifi` 的 `latestInfo`）。不含 SSID / BSSID（D10）。
public struct WiFiInfo: Hashable, Codable, Sendable {
    public var interfaceName: String
    public var powerOn: Bool
    /// 信道号；未关联时为 nil。
    public var channel: Int?
    /// 频段，GHz：2.4、5、6。
    public var bandGHz: Double?
    /// 信道带宽，MHz：20、40、80、160（SDK 仍没有 320 MHz 的枚举）。
    public var widthMHz: Int?
    /// PHY 模式：「802.11be」等。
    public var phyMode: String?
    /// 发送功率原值，mW：M4 实测不可信（1496 mW），只进诊断页。
    public var transmitPowerRaw: Int?

    public init(
        interfaceName: String, powerOn: Bool, channel: Int?, bandGHz: Double?, widthMHz: Int?, phyMode: String?,
        transmitPowerRaw: Int?
    ) {
        self.interfaceName = interfaceName
        self.powerOn = powerOn
        self.channel = channel
        self.bandGHz = bandGHz
        self.widthMHz = widthMHz
        self.phyMode = phyMode
        self.transmitPowerRaw = transmitPowerRaw
    }
}

/// 一个接口最近一次读到的累计计数（诊断页、CLI `--diag`）。
public struct NetworkCounters: Hashable, Codable, Sendable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    public var errorsIn: UInt64
    public var errorsOut: UInt64
    public var dropsIn: UInt64
    public var multicastIn: UInt64
    public var multicastOut: UInt64
    public var collisions: UInt64

    public init(
        bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64, errorsIn: UInt64, errorsOut: UInt64,
        dropsIn: UInt64, multicastIn: UInt64, multicastOut: UInt64, collisions: UInt64
    ) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
        self.dropsIn = dropsIn
        self.multicastIn = multicastIn
        self.multicastOut = multicastOut
        self.collisions = collisions
    }
}
