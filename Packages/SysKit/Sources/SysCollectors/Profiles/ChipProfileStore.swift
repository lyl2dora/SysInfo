// 芯片档案的加载与匹配（CPU 模块设计 §4.3、§5.5，D33）。
//
// - SoC 标识：IORegistry 里 pmgr 节点下 PMGR 驱动的类名（M5 Pro 为 AppleT6050PMGR，M4 Pro 为 AppleT6041PMGR）；
// - 先找内置档案，没有时再找本机校准缓存（按 socID + 系统 build，D37）；都没有就是「未知芯片」；
// - 档案的拓扑期望必须与运行时拓扑一致才使用，否则视为不匹配（同一 SoC 的屏蔽核变体等）。

import Foundation
import IOKit
import SysModel

public enum ChipIdentity {
    /// 本机的 SoC 标识；读不到时为 nil。
    public static func socID() -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let node = IOIteratorNext(iterator), node != 0 {
            defer { IOObjectRelease(node) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(node, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                var name = [CChar](repeating: 0, count: 128)
                guard IOObjectGetClass(child, &name) == KERN_SUCCESS else { continue }
                let className = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if className.hasSuffix("PMGR") { return className }
            }
        }
        return nil
    }
}

/// 档案从哪里来。
public enum ChipProfileOrigin: String, Hashable, Codable, Sendable {
    /// 随 app 发布的内置档案。
    case bundled
    /// 本机「传感器校准」的结果（按 socID + 系统 build 缓存）。
    case calibrated
}

public struct ResolvedChipProfile: Hashable, Sendable {
    public var profile: ChipProfile
    public var origin: ChipProfileOrigin
    /// 当前系统 build 是否在档案的已验证列表里（不在时照常使用，诊断页提示）。
    public var buildVerified: Bool
}

public enum ChipProfileStore {
    /// 全部内置档案。
    public static func bundledProfiles() -> [ChipProfile] {
        guard let directory = Bundle.module.url(forResource: "ChipProfiles", withExtension: nil),
            let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ChipProfile.self, from: $0) }
        }
    }

    /// 本机校准缓存的目录：`~/Library/Application Support/<bundle id>/Calibration`（Debug 与 Release 天然隔离，D16）。
    public static func calibrationDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let id = Bundle.main.bundleIdentifier ?? "sysinfo-cli"
        return base.appendingPathComponent(id, isDirectory: true).appendingPathComponent("Calibration", isDirectory: true)
    }

    static func calibrationURL(socID: String, build: String) -> URL? {
        calibrationDirectory()?.appendingPathComponent("\(socID)-\(build).json")
    }

    /// 保存一份校准结果，返回保存位置。
    @discardableResult
    public static func saveCalibration(_ profile: ChipProfile, build: String) throws -> URL? {
        guard let url = calibrationURL(socID: profile.socID, build: build) else { return nil }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(profile).write(to: url, options: .atomic)
        return url
    }

    /// 为本机找档案（D37）：有匹配的内置档案就用内置档案；没有时才用本机校准缓存。拓扑期望不符的都不用。
    /// 校准会多带进 die/SoC 传感器、让簇最高温偏高，所以对已有内置档案的芯片，校准只生成核对报告。
    public static func resolve(
        socID: String?, build: String?, topology: CPUTopology, bundled: [ChipProfile]? = nil,
        useCalibration: Bool = true
    ) -> ResolvedChipProfile? {
        guard let socID else { return nil }
        let candidates = bundled ?? bundledProfiles()
        if let profile = candidates.first(where: { $0.socID == socID }), profile.topology.matches(topology) {
            return ResolvedChipProfile(
                profile: profile, origin: .bundled, buildVerified: build.map(profile.verifiedBuilds.contains) ?? false)
        }
        guard useCalibration, let build, let url = calibrationURL(socID: socID, build: build),
            let data = try? Data(contentsOf: url),
            let profile = try? JSONDecoder().decode(ChipProfile.self, from: data), profile.topology.matches(topology)
        else { return nil }
        return ResolvedChipProfile(profile: profile, origin: .calibrated, buildVerified: true)
    }

    public static func encode(_ profile: ChipProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(profile)
    }
}
