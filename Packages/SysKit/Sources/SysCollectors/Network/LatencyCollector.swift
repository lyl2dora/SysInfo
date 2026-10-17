// 延迟采集器 `network.latency`（网络模块设计 §5.4，D61）：ICMP echo，非 root（SOCK_DGRAM），inline 通道。
//
// - 默认关（D22：默认没有出站连接）；目标由 app 设置：默认网关（来自清单，发往网关不需要本地网络授权，
//   2026-10-17 实测）与 / 或自定义地址（IP 字面量或主机名；主机名在目标变化时与每 10 分钟解析一次）；
// - 只在延迟开启、且网络面板可见或延迟 widget 打开时有需求，间隔不少于 2 s；
// - 回包由私有队列上的 DispatchSource 异步接收，按 id + seq 匹配（IPv6 另按 type 过滤）；`sample()` 只发新的探测包、
//   汇总上一间隔收到的回包，不阻塞引擎；超过 2 s 没回的算丢失；
// - RTT 输出本间隔回包的均值；丢包率按最近 10 个已有结论的探测包。
//
// 自检（K19）：能创建 ICMP DGRAM 套接字（必需）。

import Darwin
import Foundation
import Synchronization
import SysModel

public final class LatencyCollector: Collector {
    public static let collectorID: CollectorID = "network.latency"
    public static let dataPath = "ICMP echo（SOCK_DGRAM，非 root）"

    /// 超过这么久没回音的探测包算丢失。
    static let timeoutNanos: UInt64 = 2_000_000_000
    /// 丢包率的窗口（已有结论的探测包个数）。
    static let lossWindow = 10
    /// 主机名的重新解析间隔。
    static let resolveInterval: Duration = .seconds(600)

    public var id: CollectorID { Self.collectorID }

    /// app 设置的目标：网关开关与自定义地址（nil 表示不测）。
    public struct Targets: Sendable, Hashable {
        public var gateway: Bool
        public var custom: String?

        public init(gateway: Bool, custom: String?) {
            self.gateway = gateway
            self.custom = custom
        }

        public static let none = Targets(gateway: false, custom: nil)
    }

    /// 一个目标的最近状态（诊断页、面板）。
    public struct TargetStatus: Sendable, Hashable {
        public var host: String
        public var address: String?
        public var sent: UInt64
        public var received: UInt64
    }

    private final class Prober: @unchecked Sendable {
        let address: String
        let family: Int32
        let fd: Int32
        let identifier: UInt16
        let source: DispatchSourceRead
        var sequence: UInt16 = 0
        /// seq → 发出时刻（连续时钟纳秒）。只在持有外层 Mutex 时访问。
        var pending: [UInt16: UInt64] = [:]
        var rtts: [Double] = []
        var timedOutThisInterval = 0
        var outcomes: [Bool] = []
        var sent: UInt64 = 0
        var received: UInt64 = 0

        init(address: String, family: Int32, fd: Int32, identifier: UInt16, source: DispatchSourceRead) {
            self.address = address
            self.family = family
            self.fd = fd
            self.identifier = identifier
            self.source = source
        }
    }

    private struct State {
        var targets: Targets = .none
        var probers: [MetricID.LatencyTarget: Prober] = [:]
        var hosts: [MetricID.LatencyTarget: String] = [:]
        var resolved: (host: String, address: String, family: Int32, at: ContinuousClock.Instant)?
    }

    private let inventory: NetworkInventory
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "zone.lyl.sysinfo.network.latency", qos: .utility)

    public init(inventory: NetworkInventory = .shared) {
        self.inventory = inventory
    }

    deinit {
        state.withLock { s in s.probers.values.forEach { $0.source.cancel() } }
    }

    /// 设置目标（app 在设置变化时调用）。
    public func setTargets(_ targets: Targets) {
        state.withLock { s in
            guard s.targets != targets else { return }
            s.targets = targets
            if !targets.gateway, let prober = s.probers.removeValue(forKey: .gateway) { prober.source.cancel() }
            if targets.custom == nil, let prober = s.probers.removeValue(forKey: .custom) { prober.source.cancel() }
        }
    }

    public var targets: Targets { state.withLock { $0.targets } }

    /// 各目标的最近状态。
    public var status: [MetricID.LatencyTarget: TargetStatus] {
        state.withLock { s in
            var out: [MetricID.LatencyTarget: TargetStatus] = [:]
            for (target, host) in s.hosts {
                let prober = s.probers[target]
                out[target] = TargetStatus(host: host, address: prober?.address, sent: prober?.sent ?? 0, received: prober?.received ?? 0)
            }
            return out
        }
    }

    public func selfTest() -> SelfTestResult {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        let ok = fd >= 0
        let detail = ok ? "SOCK_DGRAM IPPROTO_ICMP ok" : "socket errno=\(errno)"
        if ok { close(fd) }
        return SelfTestResult(checks: [SelfTestCheck(name: "network.latency.socket", passed: ok, detail: detail)], dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let targets = state.withLock { $0.targets }
        var wanted: [MetricID.LatencyTarget: String] = [:]
        if targets.gateway {
            let snapshot = inventory.snapshot()
            if let gateway = snapshot.gatewayIPv4 ?? snapshot.gatewayIPv6 { wanted[.gateway] = gateway }
        }
        if let custom = targets.custom?.trimmingCharacters(in: .whitespaces), !custom.isEmpty { wanted[.custom] = custom }

        var samples: [Sample] = []
        for target in MetricID.LatencyTarget.allCases {
            let enabled = target == .gateway ? targets.gateway : (targets.custom != nil)
            guard enabled else { continue }
            guard let host = wanted[target], let (address, family) = resolve(host) else {
                state.withLock { s in
                    s.hosts[target] = wanted[target] ?? ""
                    if let prober = s.probers.removeValue(forKey: target) { prober.source.cancel() }
                }
                samples.append(.unavailable(.networkLatencyRTT(target), reason: .noTarget(), at: time))
                continue
            }
            samples += collect(target: target, host: host, address: address, family: family, time: time)
        }
        return CollectorOutput(samples: samples, status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock { s in
            for prober in s.probers.values {
                prober.pending = [:]
                prober.rtts = []
                prober.timedOutThisInterval = 0
            }
        }
    }

    // MARK: - 探测

    /// 汇总一个目标上一间隔的结果，再发一个新的探测包。
    private func collect(target: MetricID.LatencyTarget, host: String, address: String, family: Int32, time: SampleTime) -> [Sample] {
        let now = time.continuousNanos
        let prober: Prober? = state.withLock { s in
            s.hosts[target] = host
            if let existing = s.probers[target], existing.address == address { return existing }
            if let old = s.probers.removeValue(forKey: target) { old.source.cancel() }
            guard let fresh = makeProber(address: address, family: family) else { return nil }
            s.probers[target] = fresh
            return fresh
        }
        guard let prober else {
            return [.unavailable(.networkLatencyRTT(target), reason: .readFailed("socket errno=\(errno)"), at: time)]
        }
        var samples: [Sample] = []
        state.withLock { _ in
            // 超时的算丢失。
            for (seq, sentAt) in prober.pending where now > sentAt && now - sentAt > Self.timeoutNanos {
                prober.pending[seq] = nil
                prober.timedOutThisInterval += 1
                prober.outcomes.append(false)
            }
            if prober.outcomes.count > Self.lossWindow { prober.outcomes.removeFirst(prober.outcomes.count - Self.lossWindow) }
            let rttID = MetricID.networkLatencyRTT(target)
            if !prober.rtts.isEmpty {
                samples.append(Sample(id: rttID, value: prober.rtts.reduce(0, +) / Double(prober.rtts.count), time: time))
            } else if prober.timedOutThisInterval > 0 {
                samples.append(.unavailable(rttID, reason: .timeout(), at: time))
            }
            if !prober.outcomes.isEmpty {
                let lost = prober.outcomes.filter { !$0 }.count
                samples.append(Sample(id: .networkLatencyLoss(target), value: Double(lost) / Double(prober.outcomes.count), time: time))
            }
            prober.rtts = []
            prober.timedOutThisInterval = 0
        }
        send(prober)
        return samples
    }

    private func makeProber(address: String, family: Int32) -> Prober? {
        let fd = socket(family, SOCK_DGRAM, family == AF_INET ? IPPROTO_ICMP : IPPROTO_ICMPV6)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let prober = Prober(address: address, family: family, fd: fd, identifier: UInt16.random(in: 1...UInt16.max), source: source)
        source.setEventHandler { [weak self, weak prober] in
            guard let self, let prober else { return }
            self.receive(prober)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return prober
    }

    /// 发一个探测包。发出时刻在 sendto 之前一刻取（不能用 tick 的采样时刻：同一 tick 里排在前面的采集器
    /// 可能要几毫秒墙钟，例如 CoreWLAN 的 XPC，会被算进 RTT）。
    private func send(_ prober: Prober) {
        let seq: UInt16 = state.withLock { _ in
            prober.sequence &+= 1
            prober.sent += 1
            return prober.sequence
        }
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = prober.family == AF_INET ? 8 : 128  // ICMP_ECHO / ICMP6_ECHO_REQUEST
        packet[4] = UInt8(prober.identifier >> 8)
        packet[5] = UInt8(prober.identifier & 0xff)
        packet[6] = UInt8(seq >> 8)
        packet[7] = UInt8(seq & 0xff)
        if prober.family == AF_INET {
            let sum = Self.checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xff)
        }  // ICMPv6 的校验和由内核填
        let result: Int = Self.withSockaddr(prober.address, family: prober.family) { sa, length in
            // 先登记再发：回包可能在 sendto 返回之前就被接收队列处理。
            state.withLock { _ in prober.pending[seq] = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
            return packet.withUnsafeBytes { sendto(prober.fd, $0.baseAddress, $0.count, 0, sa, length) }
        } ?? -1
        if result < 0 {
            // 发不出去（例如被本地网络隐私拦截、无路由）：直接记为丢失。
            state.withLock { _ in
                prober.pending[seq] = nil
                prober.outcomes.append(false)
                prober.timedOutThisInterval += 1
            }
        }
    }

    private func receive(_ prober: Prober) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(prober.fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            guard let (type, identifier, seq) = Self.parseReply(Array(buffer[..<n]), family: prober.family),
                identifier == prober.identifier
            else { continue }
            let isReply = prober.family == AF_INET ? type == 0 : type == 129
            guard isReply else { continue }
            state.withLock { _ in
                guard let sentAt = prober.pending.removeValue(forKey: seq), now >= sentAt else { return }
                prober.rtts.append(Double(now - sentAt) / 1e9)
                prober.outcomes.append(true)
                prober.received += 1
            }
        }
    }

    /// 解析回包：返回 type、id、seq。IPv4 DGRAM 套接字收到的数据带 IP 头（2026-09-28 实测），按版本号判断后跳过。
    static func parseReply(_ data: [UInt8], family: Int32) -> (type: UInt8, identifier: UInt16, seq: UInt16)? {
        var offset = 0
        if family == AF_INET, let first = data.first, first >> 4 == 4 { offset = Int(first & 0x0f) * 4 }
        guard data.count >= offset + 8 else { return nil }
        let type = data[offset]
        let identifier = UInt16(data[offset + 4]) << 8 | UInt16(data[offset + 5])
        let seq = UInt16(data[offset + 6]) << 8 | UInt16(data[offset + 7])
        return (type, identifier, seq)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    // MARK: - 地址

    /// IP 字面量直接用；主机名用 getaddrinfo 解析（缓存 10 分钟）。
    private func resolve(_ host: String) -> (String, Int32)? {
        if Self.withSockaddr(host, family: AF_INET, { _, _ in 0 }) != nil { return (host, AF_INET) }
        if Self.withSockaddr(host, family: AF_INET6, { _, _ in 0 }) != nil { return (host, AF_INET6) }
        let now = ContinuousClock.now
        if let cached = state.withLock({ $0.resolved }), cached.host == host, now - cached.at < Self.resolveInterval {
            return (cached.address, cached.family)
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        var chosen: (String, Int32)?
        while let entry = p, chosen == nil {
            defer { p = entry.pointee.ai_next }
            guard let sa = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch entry.pointee.ai_family {
            case AF_INET:
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil { chosen = (NetworkSysctl.string(buffer), AF_INET) }
            case AF_INET6:
                var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil { chosen = (NetworkSysctl.string(buffer), AF_INET6) }
            default:
                continue
            }
        }
        if let chosen { state.withLock { $0.resolved = (host, chosen.0, chosen.1, now) } }
        return chosen
    }

    /// 把 IP 字面量转成 sockaddr 调用 body；不是该族的字面量时返回 nil。
    static func withSockaddr<T>(_ address: String, family: Int32, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        if family == AF_INET {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return nil }
            return withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        // 链路本地网关带 %scope：拆开，scope 转成接口 index。
        let parts = address.split(separator: "%", maxSplits: 1)
        guard inet_pton(AF_INET6, String(parts[0]), &sin6.sin6_addr) == 1 else { return nil }
        if parts.count == 2 { sin6.sin6_scope_id = if_nametoindex(String(parts[1])) }
        return withUnsafePointer(to: &sin6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }
}
