// 网络接口清单与连接状态（网络模块设计 §5.1，D60）：`network.io` 与 app 共用一份。
//
// - SCDynamicStore 的变更通知只把「脏」标记置位，下一次取快照时重建；另外每 60 s 强制重建一次
//   （虚拟机网卡等不经 configd 管理的接口没有通知）；
// - 分类按 IOKit 控制器类、SC 类型与 IFMIB 类型在运行时判断，不按接口名或驱动类名写死（两台机器的
//   内置 10 GbE 驱动类不同：Skywalk 与 Aquantia）；
// - 主接口：默认路由接口不是隧道时就是它；是隧道时取 `ServiceOrder` 里第一个有 IPv4 状态的非隧道服务的接口
//   （代理软件 TUN 实测：utun 只计隧道内层，经系统代理的流量不经过 utun，en0 才是线上真实流量）；
// - 地址只放在内存里给面板与 CLI 显示，不写日志；
// - 只用公开接口：sysctl IFMIB、SIOCGIFMEDIA、getifaddrs、SystemConfiguration、IOKit。

import Darwin
import Foundation
import IOKit
import os
import Synchronization
import SystemConfiguration
import SysModel

public final class NetworkInventory: Sendable {
    /// app 与 CLI 共用的实例。
    public static let shared = NetworkInventory()

    /// 强制重建的最长间隔。
    static let refreshInterval: Duration = .seconds(60)

    private struct State {
        var snapshot: NetworkState?
        var dirty = true
        var generation: UInt64 = 0
        var lastBuild: ContinuousClock.Instant?
        var storeInstalled = false
        /// 上次重建时的接口列表（名字 + index）：周期检查时没变就不重建。
        var lastIndices: [String] = []
        /// IOKit 控制器类，按「名字#index」缓存：同一个接口实例的控制器不会变，查一次约 1.9 ms（2026-10-17 实测，
        /// 每 60 s 对 40 个接口全查一遍曾让出厂默认档多出约 0.13% 单核）。
        var controllers: [String: String?] = [:]
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "zone.lyl.sysinfo.network.inventory", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sysinfo-cli", category: "network")
    /// SCDynamicStore 只在私有队列上访问。
    private nonisolated(unsafe) var store: SCDynamicStore?

    public init() {}

    /// 最近一次重建的状态（不触发重建）。
    public var current: NetworkState { state.withLock { $0.snapshot ?? .empty } }

    /// 让下一次取快照时重建（自检、唤醒、IFMIB 读失败）。
    public func invalidate() {
        state.withLock { $0.dirty = true }
    }

    /// 当前状态：脏了或超过 60 s 时重建。
    public func snapshot() -> NetworkState {
        installStoreIfNeeded()
        let now = ContinuousClock.now
        let cached: NetworkState? = state.withLock { s in
            guard let snapshot = s.snapshot, !s.dirty, let last = s.lastBuild else { return nil }
            return now - last < Self.refreshInterval ? snapshot : nil
        }
        if let cached { return cached }
        // 周期检查（没有变更通知）：接口列表没变就沿用上次的结果，只枚举一次（约 0.2 ms）。
        let indices = Self.interfaceIndices().map { "\($0.0)#\($0.1)" }
        let unchanged: NetworkState? = state.withLock { s in
            guard let snapshot = s.snapshot, !s.dirty, s.lastIndices == indices else { return nil }
            s.lastBuild = now
            return snapshot
        }
        if let unchanged { return unchanged }
        let known = state.withLock { $0.controllers }
        let (fresh, controllers) = queue.sync { Self.build(store: store, controllers: known) }
        let (result, changed) = state.withLock { s -> (NetworkState, Bool) in
            var fresh = fresh
            let old = s.snapshot
            fresh.generation = s.generation
            let changed = old.map { var o = $0; o.generation = fresh.generation; return o != fresh } ?? true
            if changed {
                s.generation &+= 1
                fresh.generation = s.generation
            }
            s.snapshot = fresh
            s.dirty = false
            s.lastBuild = now
            s.lastIndices = indices
            s.controllers = controllers
            return (fresh, changed)
        }
        if changed {
            let physical = result.physical.map(\.name).joined(separator: ",")
            let primary = result.primary ?? "-"
            let vpn = result.vpnActive
            let count = result.interfaces.count
            logger.info(
                "网络清单更新：主接口 \(primary, privacy: .public)，VPN \(vpn)，物理 [\(physical, privacy: .public)]，共 \(count) 个接口（第 \(result.generation) 代）"
            )
        }
        return result
    }

    // MARK: - 变更通知

    private func installStoreIfNeeded() {
        let install = state.withLock { s -> Bool in
            guard !s.storeInstalled else { return false }
            s.storeInstalled = true
            return true
        }
        guard install else { return }
        queue.sync {
            var context = SCDynamicStoreContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<NetworkInventory>.fromOpaque(info).takeUnretainedValue().invalidate()
            }
            guard let store = SCDynamicStoreCreate(nil, "zone.lyl.sysinfo.network" as CFString, callback, &context) else {
                logger.error("SCDynamicStoreCreate 失败，网络清单只按 60 s 周期重建")
                return
            }
            let keys = [
                "State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS",
                "State:/Network/Global/Proxies", "Setup:/Network/Global/IPv4", "State:/Network/Interface",
            ]
            let patterns = [
                "State:/Network/Interface/[^/]+/(Link|IPv4|IPv6)", "State:/Network/Service/[^/]+/(IPv4|IPv6|VPN)",
            ]
            SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(store, queue)
            self.store = store
        }
        // 实例随进程存在（shared 不释放），store 不再注销。
    }

    // MARK: - 重建

    /// 一个接口的原始信息（分类前）。
    struct RawInterface: Sendable {
        var name: String
        var index: UInt32
        var ifType: UInt8
        var flags: UInt32
        var hasMedia: Bool
        var mediaActive: Bool
        var mediaIsWiFi: Bool
        var bytesIn: UInt64
        var ipv4: [String]
        var ipv6Global: [String]
        var scType: String?
        var displayName: String?
        var hasIOKit: Bool
        var controllerClass: String?
    }

    /// 分类（纯函数，便于单测）：返回类型与是否物理；不进清单的接口返回 nil。
    static func classify(_ raw: RawInterface) -> (kind: NetworkInterfaceKind, physical: Bool, active: Bool)? {
        let up = raw.flags & UInt32(IFF_UP) != 0
        let running = raw.flags & UInt32(IFF_RUNNING) != 0
        if raw.flags & UInt32(IFF_LOOPBACK) != 0 { return nil }
        let routable = !raw.ipv4.isEmpty || !raw.ipv6Global.isEmpty
        let controller = raw.controllerClass ?? ""
        let kind: NetworkInterfaceKind
        var physical = false
        if raw.ifType == UInt8(IFT_GIF) || raw.ifType == UInt8(IFT_STF) { return nil }
        if raw.scType == "Bridge" {
            kind = .bridge
            physical = true
        } else if raw.hasIOKit, !controller.isEmpty {
            if controller == "IOUserEthernetController" {
                kind = .virtualMachine
            } else if controller.contains("USBDeviceNCM") || controller.contains("ThunderboltIP") {
                // Mac 作 USB 设备时的接口；雷电 IP 端口是 Thunderbolt Bridge 的成员，由 bridge0 代表（避免重复计数）。
                return nil
            } else if raw.scType == "IEEE80211" {
                kind = .wifi
                physical = true
            } else if raw.scType == "Ethernet" {
                kind = .ethernet
                physical = true
            } else {
                kind = .other
            }
        } else if raw.ifType == UInt8(IFT_BRIDGE) {
            kind = .virtualMachine
        } else if raw.flags & UInt32(IFF_POINTOPOINT) != 0 || raw.ifType == UInt8(IFT_PPP) || raw.ifType == UInt8(IFT_OTHER) {
            kind = .tunnel
        } else if raw.mediaIsWiFi {
            kind = .awdl
        } else {
            kind = .other
        }
        let active: Bool
        if physical {
            active = up && ((raw.hasMedia && raw.mediaActive) || routable)
        } else {
            active = up && running && ((raw.hasMedia && raw.mediaActive) || routable || raw.bytesIn > 0)
        }
        guard active else { return nil }
        return (kind, physical, active)
    }

    static func isTunnelName(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "gif"].contains { name.hasPrefix($0) }
    }

    /// 重建清单。`controllers` 是已知的控制器类缓存（键「名字#index」，值为 nil 表示没有 IOKit 接口）；返回更新后的缓存。
    static func build(store: SCDynamicStore?, controllers known: [String: String?] = [:]) -> (NetworkState, [String: String?]) {
        var controllers: [String: String?] = [:]
        // SCNetworkInterface：类型与本地化名。
        var scInfo: [String: (type: String?, name: String?)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                scInfo[bsd] = (
                    SCNetworkInterfaceGetInterfaceType(interface) as String?,
                    SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                )
            }
        }
        let addresses = Self.addresses()
        var raws: [RawInterface] = []
        for (name, index) in Self.interfaceIndices() {
            guard let mib = NetworkSysctl.read(index: index) else { continue }
            let media = NetworkSysctl.media(name)
            let cacheKey = "\(name)#\(index)"
            let controller: String??
            if let cached = known[cacheKey] {
                controller = .some(cached)
            } else {
                controller = Self.ioKitInfo(name).map { $0.controller }
            }
            controllers[cacheKey] = controller ?? nil
            let io: (controller: String?, linkSpeed: Double?)? = controller.map { ($0, nil) }
            raws.append(
                RawInterface(
                    name: name, index: index, ifType: mib.ifType, flags: mib.flags, hasMedia: media != nil,
                    mediaActive: media?.active ?? false, mediaIsWiFi: media?.isWiFi ?? false, bytesIn: mib.counters.bytesIn,
                    ipv4: addresses[name]?.v4 ?? [], ipv6Global: addresses[name]?.v6 ?? [], scType: scInfo[name]?.type,
                    displayName: scInfo[name]?.name, hasIOKit: io != nil, controllerClass: io?.controller))
        }
        var interfaces: [NetworkInterface] = []
        for raw in raws {
            guard let (kind, physical, active) = classify(raw) else { continue }
            var speed: Double?
            if physical, kind == .ethernet, let linkSpeed = Self.ioKitInfo(raw.name, linkSpeed: true)?.linkSpeed, linkSpeed > 0 {
                speed = linkSpeed
            }
            interfaces.append(
                NetworkInterface(
                    name: raw.name, index: raw.index, kind: kind, displayName: raw.displayName, isPhysical: physical,
                    isActive: active, linkSpeed: speed, controllerClass: raw.controllerClass, scType: raw.scType,
                    ifType: raw.ifType, ipv4: raw.ipv4, ipv6: raw.ipv6Global))
        }
        interfaces.sort { a, b in
            if a.isPhysical != b.isPhysical { return a.isPhysical }
            return a.index < b.index
        }

        // 主接口、VPN、网关、DNS、代理。
        func value(_ key: String) -> [String: Any]? {
            guard let store else { return nil }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        let global4 = value("State:/Network/Global/IPv4")
        let global6 = value("State:/Network/Global/IPv6")
        let defaultRoute = global4?["PrimaryInterface"] as? String ?? global6?["PrimaryInterface"] as? String
        let primaryService = global4?["PrimaryService"] as? String ?? global6?["PrimaryService"] as? String
        let routeIsTunnel = defaultRoute.map(isTunnelName) ?? false
        let serviceHasVPN = primaryService.map { value("State:/Network/Service/\($0)/VPN") != nil } ?? false
        var primary = defaultRoute
        var physicalService = primaryService
        if routeIsTunnel || serviceHasVPN {
            primary = nil
            physicalService = nil
            let order = value("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
            for service in order {
                guard let ipv4 = value("State:/Network/Service/\(service)/IPv4"),
                    let name = ipv4["InterfaceName"] as? String, !isTunnelName(name)
                else { continue }
                primary = name
                physicalService = service
                break
            }
        }
        // 主接口不在清单里（例如链路刚断）时当作离线。
        if let p = primary, !interfaces.contains(where: { $0.name == p }) { primary = nil }
        let gateway4 = physicalService.flatMap { value("State:/Network/Service/\($0)/IPv4")?["Router"] as? String }
        let gateway6 = physicalService.flatMap { value("State:/Network/Service/\($0)/IPv6")?["Router"] as? String }
        let dns = value("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []
        let proxies = value("State:/Network/Global/Proxies") ?? [:]
        let proxyEnabled = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].contains {
            (proxies[$0] as? NSNumber)?.boolValue == true
        }
        let state = NetworkState(
            interfaces: interfaces, primary: primary, defaultRouteInterface: defaultRoute,
            vpnActive: routeIsTunnel || serviceHasVPN, gatewayIPv4: gateway4, gatewayIPv6: gateway6, dnsServers: dns,
            proxyEnabled: proxyEnabled, generation: 0)
        return (state, controllers)
    }

    /// 全部接口的名字与 index。
    static func interfaceIndices() -> [(String, UInt32)] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var out: [(String, UInt32)] = []
        var p = list
        while p.pointee.if_index != 0 {
            if let name = p.pointee.if_name { out.append((String(cString: name), p.pointee.if_index)) }
            p += 1
        }
        return out
    }

    /// 每个接口的 IPv4 与非链路本地 IPv6 地址。
    static func addresses() -> [String: (v4: [String], v6: [String])] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var out: [String: (v4: [String], v6: [String])] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = p {
            defer { p = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
                out[name, default: ([], [])].v4.append(NetworkSysctl.string(buffer))
            case AF_INET6:
                var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                // 链路本地（fe80::/10）不显示。
                let isLinkLocal = addr.__u6_addr.__u6_addr8.0 == 0xfe && (addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
                let isLoopback = withUnsafeBytes(of: &addr) { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
                guard !isLinkLocal, !isLoopback, inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else {
                    continue
                }
                out[name, default: ([], [])].v6.append(NetworkSysctl.string(buffer))
            default:
                continue
            }
        }
        return out
    }

    /// IOKit：接口背后的控制器类与链路速率（bit/s）。没有 IONetworkInterface 时返回 nil。
    static func ioKitInfo(_ name: String, linkSpeed: Bool = false) -> (controller: String?, linkSpeed: Double?)? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name),
            let interface = IORegistryObject(owning: IOServiceGetMatchingService(kIOMainPortDefault, matching))
        else { return nil }
        guard let controller = interface.parent else { return (nil, nil) }
        var speed: Double?
        if linkSpeed, let value = controller.uint64("IOLinkSpeed"), let status = controller.uint64("IOLinkStatus"),
            status & 0x3 == 0x3
        {
            // IOLinkStatus：bit0 有效、bit1 活跃（kIONetworkLinkValid | kIONetworkLinkActive）。
            speed = Double(value)
        }
        return (controller.className, speed)
    }
}

/// IFMIB 与 SIOCGIFMEDIA 的读取（公开接口）。
enum NetworkSysctl {
    struct Reading {
        var ifType: UInt8
        var flags: UInt32
        var counters: NetworkCounters
    }

    /// `sysctl net.link.generic.ifdata.<index>.general`：64 位计数（D11：字节计数只用 IFMIB）。
    static func read(index: UInt32) -> Reading? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0, size == MemoryLayout<ifmibdata>.size else {
            return nil
        }
        let d = data.ifmd_data
        return Reading(
            ifType: d.ifi_type, flags: data.ifmd_flags,
            counters: NetworkCounters(
                bytesIn: d.ifi_ibytes, bytesOut: d.ifi_obytes, packetsIn: d.ifi_ipackets, packetsOut: d.ifi_opackets,
                errorsIn: d.ifi_ierrors, errorsOut: d.ifi_oerrors, dropsIn: d.ifi_iqdrops, multicastIn: d.ifi_imcasts,
                multicastOut: d.ifi_omcasts, collisions: d.ifi_collisions))
    }

    /// 以 NUL 结尾的 C 字符串缓冲区 → String。
    static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `_IOWR('i', 56, struct ifmediareq)`：Swift 看不到这个宏，按 ioccom.h 的规则算出来。
    static let siocgifmedia: UInt = 0xC000_0000 | (UInt(MemoryLayout<ifmediareq>.size & 0x1fff) << 16) | (0x69 << 8) | 56

    /// 链路状态；接口不支持媒体查询（utun 等）时返回 nil。
    static func media(_ name: String) -> (active: Bool, isWiFi: Bool, activeWord: Int32)? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { buffer in
            let bytes = Array(name.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
        }
        guard ioctl(fd, siocgifmedia, &request) == 0 else { return nil }
        let valid = request.ifm_status & 0x1 != 0  // IFM_AVALID
        let active = valid && request.ifm_status & 0x2 != 0  // IFM_ACTIVE
        let isWiFi = request.ifm_active & 0xe0 == 0x80  // IFM_TYPE == IFM_IEEE80211
        return (active, isWiFi, request.ifm_active)
    }
}
