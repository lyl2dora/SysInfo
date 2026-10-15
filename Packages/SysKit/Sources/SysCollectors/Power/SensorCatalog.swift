// 传感器目录 `sensors.catalog`（功耗与散热模块设计 §4.5，D44 PT6）。只在诊断页展开目录时采样，走阻塞通道。
//
// - 第一次采样时全量枚举 SMC 键名与 key-info（M4 约 120 ms，只做一次）；之后每次读 T/V/I/P/F 开头的数值键；
// - 每个键给出数据质量：有效 / 占位 / 恒定 / 非温度；只按会话内的观察和档案判断，不按键名猜含义；
// - 分组只用档案：CPU 簇键（D33）、最热点键、经负载验证的前缀分组（`Tg*` 随 GPU、`Ta*` 随 ANE）。其余只显示原始键名。

import Foundation
import Synchronization
import SysModel

/// 目录里一个键的状态。
public struct SensorCatalogEntry: Hashable, Sendable, Identifiable {
    public enum Quality: String, Hashable, Sendable {
        /// 会变化、在合理范围内的读数。
        case valid
        /// 等于档案里的占位值（断电或刚上电）。
        case placeholder
        /// 本次会话里从没变化过。
        case constant
        /// `T` 开头但读数不像温度（超过 150）。
        case nonTemperature
        /// 读取失败。
        case unreadable
    }

    public var id: String { key }
    public var key: String
    public var dataType: String
    public var value: Double?
    public var quality: Quality
    /// 经验证的分组：`cpu.<簇>`、`hotspot`、档案 catalogGroups 的名字（`gpu`、`ane`）；没有时为 nil。
    public var group: String?
}

public final class SensorCatalog: Collector {
    public static let collectorID: CollectorID = "sensors.catalog"
    public static let dataPath = "AppleSMC full enumeration (read-only)"
    static let prefixes: Set<Character> = ["T", "V", "I", "P", "F"]

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking

    private struct KeyState {
        var info: SMCKeyInfo
        var first: Double?
        var changed = false
        var value: Double?
    }

    private struct State {
        var keys: [String: KeyState] = [:]
        var order: [String] = []
        var groups: [String: String] = [:]
        /// 键前缀 → 分组名（档案 catalogGroups）。
        var prefixGroups: [String: String] = [:]
        var placeholders: [Double] = []
        var enumerated = false
        var entries: [SensorCatalogEntry] = []
        var samples = 0
    }

    private let state = Mutex(State())
    private let smc: SMCReader
    private let resolveProfile: @Sendable () -> ResolvedChipProfile?

    public convenience init() {
        self.init(smc: SMCReader(), resolveProfile: { PowerProfiles.resolve() })
    }

    init(smc: SMCReader, resolveProfile: @escaping @Sendable () -> ResolvedChipProfile?) {
        self.smc = smc
        self.resolveProfile = resolveProfile
    }

    /// 最近一次采样的目录，按键名排序。
    public var entries: [SensorCatalogEntry] { state.withLock { $0.entries } }
    /// 已经采样的次数（「恒定」需要多次观察才有意义）。
    public var sampleCount: Int { state.withLock { $0.samples } }

    public func selfTest() -> SelfTestResult {
        let check: SelfTestCheck
        do {
            try smc.open()
            check = SelfTestCheck(name: "sensors.catalog.smc", passed: true, detail: "\(try smc.keyCount()) keys")
        } catch {
            check = SelfTestCheck(name: "sensors.catalog.smc", passed: false, detail: error.description)
        }
        // 档案的分组：CPU 簇键、最热点、前缀分组。
        let profile = resolveProfile()?.profile
        var groups: [String: String] = [:]
        // 几个簇共用同一组键时（M4 Pro 的两个 P 簇，D36），分组名列出全部簇：`cpu.d0c1+d0c2`。
        var clustersByKey: [String: [String]] = [:]
        for (cluster, keys) in profile?.temperature.clusters ?? [:] {
            for key in keys { clustersByKey[key, default: []].append(cluster) }
        }
        for (key, clusters) in clustersByKey { groups[key] = "cpu." + clusters.sorted().joined(separator: "+") }
        if let hotspot = profile?.system?.hotspotKey { groups[hotspot] = "hotspot" }
        let prefixGroups = profile?.system?.catalogGroups ?? [:]
        state.withLock {
            $0.groups = groups
            $0.prefixGroups = Dictionary(prefixGroups.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
            $0.placeholders = profile?.system?.placeholders ?? profile?.temperature.sentinels ?? []
        }
        return SelfTestResult(checks: [check], dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        enumerateIfNeeded()
        let keys = state.withLock { s in s.order.compactMap { s.keys[$0].map { ($0.info) } } }
        var values: [String: Double] = [:]
        for info in keys {
            guard let bytes = try? smc.readRaw(info), let value = SMCDecoder.decode(info, bytes: bytes) else { continue }
            values[info.key.description] = value
        }
        state.withLock { s in
            s.samples += 1
            for (name, value) in values {
                guard var k = s.keys[name] else { continue }
                if let first = k.first, first != value { k.changed = true }
                if k.first == nil { k.first = value }
                k.value = value
                s.keys[name] = k
            }
            for name in s.order where values[name] == nil { s.keys[name]?.value = nil }
            s.entries = s.order.compactMap { name in
                guard let k = s.keys[name] else { return nil }
                return SensorCatalogEntry(
                    key: name, dataType: k.info.dataType.trimmingCharacters(in: .whitespaces), value: k.value,
                    quality: Self.classify(name, k, placeholders: s.placeholders, samples: s.samples),
                    group: Self.group(name, exact: s.groups, prefixes: s.prefixGroups))
            }
        }
        return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    // MARK: - 私有

    private func enumerateIfNeeded() {
        guard !state.withLock({ $0.enumerated }) else { return }
        let all = (try? smc.allKeys()) ?? []
        var keys: [String: KeyState] = [:]
        var order: [String] = []
        for key in all {
            let name = key.description
            guard let first = name.first, Self.prefixes.contains(first), let info = try? smc.keyInfo(for: key),
                SMCDecoder.decode(info, bytes: [UInt8](repeating: 0, count: 32)) != nil
            else { continue }
            keys[name] = KeyState(info: info)
            order.append(name)
        }
        state.withLock {
            $0.keys = keys
            $0.order = order.sorted()
            $0.enumerated = true
        }
    }

    private static func classify(_ name: String, _ k: KeyState, placeholders: [Double], samples: Int) -> SensorCatalogEntry.Quality {
        guard let value = k.value else { return .unreadable }
        if name.hasPrefix("T") {
            if value > 150 { return .nonTemperature }
            if isPlaceholder(value, in: placeholders) { return .placeholder }
        }
        if samples >= 3, !k.changed { return .constant }
        return .valid
    }

    static func group(_ name: String, exact: [String: String], prefixes: [String: String]) -> String? {
        if let group = exact[name] { return group }
        return prefixes.first { name.hasPrefix($0.key) }?.value
    }
}
