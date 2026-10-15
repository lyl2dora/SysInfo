// sysinfo-cli topo（CPU 模块设计 §8）：打印拓扑发现的结果，用于两台目标机对照（D28）。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    struct TopoReport: Encodable {
        var machine: MachineInfo
        var topology: CPUTopology
    }

    /// 退出码：拓扑判定成立（quality == ok）为 0，否则为 1。
    static func runTopo(json: Bool) -> Int32 {
        let topology = TopologyResolver.resolve(TopologyReader.readInputs())
        if json {
            let report = TopoReport(machine: .current, topology: topology)
            print(String(decoding: (try? makeEncoder().encode(report)) ?? Data(), as: UTF8.self))
            return topology.quality.isOK ? 0 : 1
        }
        print(machineLine())
        switch topology.quality {
        case .ok: print("拓扑：成立")
        case .clustersOnly(let reason): print("拓扑：只按簇显示（\(reason)）")
        case .coresOnly(let reason): print("拓扑：只按核显示（\(reason)）")
        }
        print("核档：")
        for level in topology.perfLevels {
            let clusters = level.clusters.map(\.description).joined(separator: ", ")
            print("  perflevel\(level.index) \(level.name) ×\(level.cpuCount)：\(clusters)")
        }
        print("簇：")
        for cluster in topology.clusters {
            let level = cluster.perfLevel.map { "perflevel\($0)" } ?? "未定档"
            let range = cluster.cpus.first.map { first in "cpu\(first)–\(cluster.cpus.last!)" } ?? "—"
            print("  \(cluster.key)  \(range)（\(cluster.cpus.count) 核）  \(cluster.classKey)  → \(level)")
        }
        print("档次依据：")
        for evidence in topology.evidence {
            let verdict = evidence.mapping == nil ? "不成立" : "成立"
            let mapping = evidence.mapping.map { m in
                " {" + m.sorted { $0.value < $1.value }.map { "\($0.key)→\($0.value)" }.joined(separator: ", ") + "}"
            } ?? ""
            print("  \(evidence.method.rawValue)：\(verdict)\(mapping)  \(evidence.detail)")
        }
        return topology.quality.isOK ? 0 : 1
    }
}
