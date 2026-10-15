// 校准结果与内置档案的比对（CPU 模块设计偏离记录 2026-10-15 的验收口径，D37）。CLI 与诊断页共用。
//
// - 内置档案里的温度键必须全部找回（召回 100%），且没有被归到别的簇；按别名组展开后比较；
// - 校准多出来的键（多为 die/SoC 传感器）只列为候选，需要人工确认，不算失败；
// - 功耗轨：同一路电的重复测量（PP*b 与 RP*）视为等价；内置的轨必须找回，多出的轨列为候选；
// - 占位值：内置的必须都识别出来。

import SysModel

public struct CalibrationComparison: Hashable, Sendable {
    public struct ClusterResult: Hashable, Sendable {
        public var cluster: String
        public var bundledCount: Int
        public var missing: [String]
        public var candidates: [String]
    }

    public var temperatures: [ClusterResult]
    public var rails: [ClusterResult]
    public var missingSentinels: [Double]

    public var passed: Bool {
        temperatures.allSatisfy(\.missing.isEmpty) && rails.allSatisfy(\.missing.isEmpty) && missingSentinels.isEmpty
    }

    public static func compare(
        bundled: ChipProfile, calibrated: ChipProfile, verdicts: [CalibrationKeyVerdict]
    ) -> CalibrationComparison {
        func expand(_ keys: [String], _ profile: ChipProfile) -> Set<String> {
            var out = Set(keys)
            for group in profile.temperature.aliasGroups where !out.isDisjoint(with: group) { out.formUnion(group) }
            return out
        }
        // 重复轨 → 保留下来的轨
        var duplicateOf: [String: String] = [:]
        for v in verdicts where v.note.hasPrefix("duplicate of ") {
            duplicateOf[v.key] = String(v.note.dropFirst("duplicate of ".count))
        }
        let clusters = Set(bundled.temperature.clusters.keys).union(calibrated.temperature.clusters.keys).sorted()
        let temperatures = clusters.map { cluster -> ClusterResult in
            let a = expand(bundled.temperature.clusters[cluster] ?? [], bundled)
            let b = expand(calibrated.temperature.clusters[cluster] ?? [], calibrated)
            return ClusterResult(
                cluster: cluster, bundledCount: a.count, missing: a.subtracting(b).sorted(),
                candidates: b.subtracting(a).sorted())
        }
        let railClusters = Set(bundled.power.clusterRails.keys).union(calibrated.power.clusterRails.keys).sorted()
        let rails = railClusters.map { cluster -> ClusterResult in
            let a = Set(bundled.power.clusterRails[cluster] ?? [])
            let kept = calibrated.power.clusterRails[cluster] ?? []
            let b = Set(kept.flatMap { k in [k] + duplicateOf.filter { $0.value == k }.map(\.key) })
            let extra = Set(kept).subtracting(a).filter { k in !a.contains { duplicateOf[$0] == k } }
            return ClusterResult(
                cluster: cluster, bundledCount: a.count, missing: a.subtracting(b).sorted(), candidates: extra.sorted())
        }
        let missingSentinels = Set(bundled.temperature.sentinels).subtracting(calibrated.temperature.sentinels).sorted()
        return CalibrationComparison(temperatures: temperatures, rails: rails, missingSentinels: missingSentinels)
    }
}
