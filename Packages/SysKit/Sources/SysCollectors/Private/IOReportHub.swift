// IOReport 的 Swift 封装（CPU 模块设计 §3、§5.4，D34）。
//
// - 全 app 共享一个 `IOReportHub`：每个组只调用一次 `IOReportCopyChannelsInGroup`，结果缓存。
//   这一步很贵（首次约 62 ms，之后每次 28–31 ms，M5 与 M4 实测），而订阅本身只要 0.1–0.3 ms；
// - 订阅按「组 + 通道筛选」建立；同一驱动的多个组合并进一个订阅时，开销约等于其中最贵的一组；
// - 样本差分后转成 Swift 值类型，采集器不接触 CF 对象和私有符号。
//
// 线程安全（2026-10-15 实测）：`IOReportChannelGetChannelName` 等访问器会往通道字典里写缓存
// （崩溃栈为 `-[__NSDictionaryM __setObject:forKey:]`），所以「只读」访问也不能并发。
// - 缓存的组字典只在 `cache` 的锁里访问，通道信息只算一次、缓存成值类型；
// - 建订阅时对组字典做深拷贝，每个订阅独占自己的 CF 对象，与缓存和其他订阅互不共享；
// - 订阅本身由单个采集器独占（见 `IOReportSubscription`）。

import CoreFoundation
import Synchronization
internal import CSysPrivate

/// 通道的识别信息：组、子组、通道名。按结构规则识别通道时用它（不按名字猜含义，CPU 模块设计 §5.4）。
public struct IOReportChannelKey: Hashable, Sendable, CustomStringConvertible {
    public var group: String
    public var subgroup: String
    public var name: String

    public init(group: String, subgroup: String, name: String) {
        self.group = group
        self.subgroup = subgroup
        self.name = name
    }

    public var description: String { "\(group) / \(subgroup) / \(name)" }
}

/// 一个通道的静态信息（来自枚举结果，不含数值）。
public struct IOReportChannelInfo: Hashable, Sendable {
    public var key: IOReportChannelKey
    public var channelID: UInt64
    public var driverName: String?
    public var unitLabel: String?
    /// 状态类通道的状态名（例如 `DOWN`、`IDLE`、`V0P18`）；计数类通道为空。
    /// 注意：`IOReportCopyChannelsInGroup` 的枚举结果里没有状态名（2026-10-15 实测为空），
    /// 需要状态名时用 `IOReportHub.stateNames(inGroup:where:)` 从一次样本里取。
    public var stateNames: [String]
}

/// 一个通道在两次样本之间的增量。
public struct IOReportChannelDelta: Hashable, Sendable {
    public var key: IOReportChannelKey
    /// 状态类通道：每个状态的驻留增量（timebase tick），顺序与 `IOReportChannelInfo.stateNames` 相同。
    public var stateResidencies: [Int64]
    /// 状态类通道的状态名（与驻留一一对应）。
    public var stateNames: [String]
    /// 计数类通道的增量；状态类通道为 0。
    public var integerValue: Int64
    /// 提供该通道的驱动（例如 `IONVMeBlockStorageDevice <id 0x100000ece>`）；同名通道按驱动区分时用。
    public var driverName: String? = nil
}

/// 全 app 共享的 IOReport 入口。
public final class IOReportHub: Sendable {
    public static let shared = IOReportHub()

    /// 一个组的枚举结果：CF 字典只在锁内使用，通道信息与 `IOReportChannels` 数组下标一一对应。
    private struct GroupEntry {
        var dictionary: CFMutableDictionary
        var infos: [IOReportChannelInfo]
    }

    private struct Cache: ~Copyable {
        var groups: [String: GroupEntry] = [:]
        var enumerationCount = 0
    }

    private let cache = Mutex(Cache())

    init() {}

    /// libIOReport 的必需符号是否都解析到（D05：解析不到就走回退或显示不可用）。
    public var isAvailable: Bool { csp_ior_available() != 0 }

    /// 至今实际调用 `IOReportCopyChannelsInGroup` 的次数（诊断页、测试核对「每组只枚举一次」）。
    public var enumerationCount: Int { cache.withLock { $0.enumerationCount } }

    /// 某个组的全部通道信息。第一次调用时枚举并缓存；不可用时返回 nil。
    public func channels(inGroup group: String) -> [IOReportChannelInfo]? {
        guard isAvailable else { return nil }
        return cache.withLock { Self.entry(group, in: &$0)?.infos }
    }

    /// 建立订阅：从每个组里挑出满足条件的通道，合并进一个订阅。
    ///
    /// 只应把同一驱动的组合并在一起；不同驱动的组分开订阅、按需启停（D34）。
    /// 没有任何通道被选中，或订阅失败时返回 nil。
    public func makeSubscription(
        selecting selections: [(group: String, include: (IOReportChannelInfo) -> Bool)]
    ) -> IOReportSubscription? {
        guard isAvailable else { return nil }
        var merged: CFMutableDictionary?
        for selection in selections {
            // 在锁内深拷贝组字典；之后的筛选、合并、订阅都只碰这份拷贝。
            guard let (copy, infos) = cache.withLock({ cache -> (CFMutableDictionary, [IOReportChannelInfo])? in
                guard let entry = Self.entry(selection.group, in: &cache),
                    let copy = Self.deepCopy(entry.dictionary)
                else { return nil }
                return (copy, entry.infos)
            }) else { continue }
            let channels = Self.channelArray(copy)
            guard channels.count == infos.count else { continue }
            let picked = zip(channels, infos).filter { selection.include($0.1) }.map(\.0)
            guard !picked.isEmpty else { continue }
            let filtered = Self.dictionary(copy, replacingChannelsWith: picked)
            if let merged {
                csp_ior_merge_channels(merged, filtered)
            } else {
                merged = filtered
            }
        }
        guard let merged, let handle = csp_ior_subscription_create(merged) else { return nil }
        return IOReportSubscription(handle: handle)
    }

    /// 从一次样本里读状态类通道的状态名（枚举结果里没有）。建一个临时订阅，只采一次。
    public func stateNames(inGroup group: String, where include: (IOReportChannelInfo) -> Bool)
        -> [IOReportChannelKey: [String]]?
    {
        let subscription = withoutActuallyEscaping(include) { include in
            makeSubscription(selecting: [(group: group, include: include)])
        }
        guard let subscription, let snapshot = subscription.snapshot()
        else { return nil }
        return Dictionary(snapshot.map { ($0.key, $0.stateNames) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - 私有

    /// 取缓存的组；没有就枚举一次。只能在 `cache` 的锁内调用。
    private static func entry(_ group: String, in cache: inout Cache) -> GroupEntry? {
        if let hit = cache.groups[group] { return hit }
        guard let dict = csp_ior_copy_channels_in_group(group as CFString, nil) else { return nil }
        cache.enumerationCount += 1
        let entry = GroupEntry(dictionary: dict, infos: channelArray(dict).map(info(of:)))
        cache.groups[group] = entry
        return entry
    }

    /// 深拷贝（容器全部可变）。通道字典里只有属性列表类型；拷贝失败时返回 nil，不退回浅拷贝。
    private static func deepCopy(_ dict: CFDictionary) -> CFMutableDictionary? {
        guard let copy = CFPropertyListCreateDeepCopy(
            kCFAllocatorDefault, dict, CFOptionFlags(CFPropertyListMutabilityOptions.mutableContainers.rawValue))
        else { return nil }
        guard CFGetTypeID(copy) == CFDictionaryGetTypeID() else { return nil }
        return unsafeDowncast(copy, to: CFMutableDictionary.self)
    }

    static func channelArray(_ dict: CFDictionary) -> [CFDictionary] {
        let key = "IOReportChannels" as CFString
        guard let raw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque()) else { return [] }
        let object = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return [] }
        let array = unsafeDowncast(object, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let item = CFArrayGetValueAtIndex(array, index) else { return nil }
            let value = Unmanaged<CFTypeRef>.fromOpaque(item).takeUnretainedValue()
            guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
            return unsafeDowncast(value, to: CFDictionary.self)
        }
    }

    private static func dictionary(_ source: CFDictionary, replacingChannelsWith channels: [CFDictionary])
        -> CFMutableDictionary
    {
        let copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, source)!
        var callbacks = kCFTypeArrayCallBacks
        let array = CFArrayCreateMutable(kCFAllocatorDefault, channels.count, &callbacks)!
        for channel in channels {
            CFArrayAppendValue(array, Unmanaged.passUnretained(channel).toOpaque())
        }
        CFDictionarySetValue(
            copy, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque(),
            Unmanaged.passUnretained(array).toOpaque())
        return copy
    }

    static func key(of channel: CFDictionary) -> IOReportChannelKey {
        IOReportChannelKey(
            group: (csp_ior_channel_group(channel) as String?) ?? "",
            subgroup: (csp_ior_channel_subgroup(channel) as String?) ?? "",
            name: (csp_ior_channel_name(channel) as String?) ?? "")
    }

    static func stateNames(of channel: CFDictionary) -> [String] {
        let count = csp_ior_state_count(channel)
        guard count > 0 else { return [] }
        return (0..<count).map { (csp_ior_state_name(channel, $0) as String?) ?? "" }
    }

    static func info(of channel: CFDictionary) -> IOReportChannelInfo {
        IOReportChannelInfo(
            key: key(of: channel),
            channelID: csp_ior_channel_id(channel),
            driverName: csp_ior_channel_driver_name(channel) as String?,
            unitLabel: csp_ior_channel_unit_label(channel) as String?,
            stateNames: stateNames(of: channel))
    }
}

/// 一个 IOReport 订阅。不跨隔离域共享：由某个采集器独占，放在它的 `Mutex` 里使用。
public final class IOReportSubscription {
    private let handle: OpaquePointer
    private var previous: CFDictionary?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        csp_ior_subscription_destroy(handle)
    }

    /// 订阅实际包含的通道数。
    public var channelCount: Int { csp_ior_subscription_channel_count(handle) }

    /// 丢弃上一次的样本：下一次 `sampleDelta()` 只建立基线。
    public func resetBaseline() {
        previous = nil
    }

    /// 取一次样本，返回各通道的累计值（不做差分，也不改动基线）。读取失败时返回 nil。
    public func snapshot() -> [IOReportChannelDelta]? {
        guard let current = csp_ior_subscription_sample(handle) else { return nil }
        return Self.values(of: current)
    }

    /// 取一次样本，并返回与上一次样本之间的增量；第一次调用（或 `resetBaseline()` 之后）只建立基线，返回空数组。
    /// 读取失败时返回 nil，并保留原基线。
    public func sampleDelta() -> [IOReportChannelDelta]? {
        guard let current = csp_ior_subscription_sample(handle) else { return nil }
        defer { previous = current }
        guard let previous else { return [] }
        guard let delta = csp_ior_samples_delta(previous, current) else { return nil }
        return Self.values(of: delta)
    }

    private static func values(of sample: CFDictionary) -> [IOReportChannelDelta] {
        IOReportHub.channelArray(sample).map { channel in
            let count = csp_ior_state_count(channel)
            if count > 0 {
                return IOReportChannelDelta(
                    key: IOReportHub.key(of: channel),
                    stateResidencies: (0..<count).map { csp_ior_state_residency(channel, $0) },
                    stateNames: IOReportHub.stateNames(of: channel),
                    integerValue: 0, driverName: csp_ior_channel_driver_name(channel) as String?)
            }
            return IOReportChannelDelta(
                key: IOReportHub.key(of: channel), stateResidencies: [], stateNames: [],
                integerValue: csp_ior_simple_integer(channel), driverName: csp_ior_channel_driver_name(channel) as String?)
        }
    }
}
