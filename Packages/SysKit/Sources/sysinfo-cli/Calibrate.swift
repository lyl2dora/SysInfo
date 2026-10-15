// sysinfo-cli calibrate（CPU 模块设计 §5.5、§8，D33）：传感器校准，生成芯片档案，并与内置档案比对。
//
//   calibrate                          只打印将要施加的负载，不运行
//   calibrate --yes [--save-recording r.json] [--emit-profile p.json] [--verbose]
//   calibrate --from-recording r.json [--emit-profile p.json] [--verbose]   离线重新分析，不施加负载

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runCalibrate(
        confirmed: Bool, saveRecording: String?, fromRecording: String?, emitProfile: String?, verbose: Bool
    ) -> Int32 {
        let recording: CalibrationRecording
        if let fromRecording {
            guard let data = FileManager.default.contents(atPath: fromRecording),
                let decoded = try? JSONDecoder().decode(CalibrationRecording.self, from: data)
            else {
                printError("读不了录制文件：\(fromRecording)")
                return 1
            }
            recording = decoded
            print("离线分析：\(fromRecording)（\(decoded.modelIdentifier ?? "?")，\(decoded.rows.count) 个样本）")
        } else {
            let topology = CPUTopologyService.shared.refresh()
            guard topology.quality.isOK else {
                printError("拓扑未判定出核档，不能校准：\(topology.quality)")
                return 1
            }
            let phases = Calibration.plan(for: topology)
            let total = phases.reduce(0) { $0 + $1.seconds }
            let cpu = phases.filter { $0.cpuThreads > 0 }.reduce(0) { $0 + $1.seconds }
            let gpu = phases.filter(\.gpu).reduce(0) { $0 + $1.seconds }
            print(machineLine())
            print(
                "传感器校准：共约 \(Int(total)) s；CPU 负载 \(Int(cpu)) s（本进程 UI QoS 自旋线程，"
                    + phases.filter { $0.cpuThreads > 0 }.map(\.name).joined(separator: "→") + "），GPU 负载 \(Int(gpu)) s（Metal 计算）。")
            guard confirmed else {
                printError("确认后加 --yes 运行")
                return 64
            }
            do {
                recording = try Calibration.record(topology: topology, phases: phases) { phase in
                    print("  · \(phase.name) \(Int(phase.seconds)) s")
                    fflush(stdout)
                }
            } catch {
                printError("校准失败：\(error)")
                return 1
            }
            if let saveRecording {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                if (try? encoder.encode(recording).write(to: URL(fileURLWithPath: saveRecording))) != nil {
                    print("原始录制已保存：\(saveRecording)")
                }
            }
        }

        let socID = recording.socID ?? "unknown"
        let description = "\(recording.modelIdentifier ?? "?") (calibrated)"
        let result = CalibrationAnalysis.analyze(recording, socID: socID, description: description, build: recording.osBuild)
        let profile = result.profile
        print("占位值：\(result.sentinels.isEmpty ? "无" : result.sentinels.map { String($0) }.joined(separator: ", "))")
        for cluster in recording.clusters {
            let name = cluster.description
            let keys = profile.temperature.clusters[name] ?? []
            let level = recording.topology.clusters.first { $0.key == cluster }?.perfLevel.map { "档\($0)" } ?? "?"
            print("\(name)（\(level)）温度 \(keys.count) 个：\(keys.joined(separator: " "))")
            if let peaks = profile.temperature.peaks[name] { print("    峰值 \(peaks.joined(separator: " "))") }
            if let nearby = profile.temperature.nearby[name] { print("    附近（只进诊断页）\(nearby.joined(separator: " "))") }
            print("    功耗轨 \(profile.power.clusterRails[name]?.joined(separator: " ") ?? "无")")
        }
        print("GPU 轨 \(profile.power.gpuRails.joined(separator: " "))；共享轨 \(profile.power.sharedRails.joined(separator: " "))")
        print("排除 \(profile.temperature.excluded.count) 个：\(profile.temperature.excluded.joined(separator: " "))")

        if verbose {
            for v in result.verdicts where v.kind != .silent {
                let s = v.sensitivities.map { String(format: "%+.2f", $0) }.joined(separator: " ")
                print(
                    String(format: "  %@ %@ %@ s=[%@] g=%+.2f R²=%.2f %@", v.key, v.kind.rawValue, v.cluster?.description ?? "-", s,
                        v.gpuSensitivity, v.r2, v.note))
            }
        }

        var matched = true
        if let bundled = ChipProfileStore.bundledProfiles().first(where: { $0.socID == socID }) {
            print("与内置档案 \(bundled.socID)（\(bundled.description)）比对：")
            matched = compare(bundled: bundled, calibrated: profile, verdicts: result.verdicts)
        } else {
            print("没有 \(socID) 的内置档案，不做比对")
        }

        if let emitProfile, let data = try? ChipProfileStore.encode(profile) {
            try? data.write(to: URL(fileURLWithPath: emitProfile))
            print("档案已写出：\(emitProfile)")
        }
        return matched ? 0 : 1
    }

    /// 按别名展开后逐簇比较。验收口径（CPU 模块设计偏离记录 2026-10-15）：
    /// - 内置档案里的温度键必须全部找回（召回 100%），且没有被归到别的簇；
    /// - 校准多出来的键（多为 die/SoC 传感器）只列为候选，需要人工确认，不算失败；
    /// - 功耗轨：同一路电的重复测量（PP*b 与 RP*）视为等价；内置的轨必须找回，多出的轨列为候选。
    static func compare(bundled: ChipProfile, calibrated: ChipProfile, verdicts: [CalibrationKeyVerdict]) -> Bool {
        func expand(_ keys: [String], _ profile: ChipProfile) -> Set<String> {
            var out = Set(keys)
            for group in profile.temperature.aliasGroups where !out.isDisjoint(with: group) { out.formUnion(group) }
            return out
        }
        // 重复轨 → 保留下来的轨
        var duplicateOf: [String: String] = [:]
        for v in verdicts where v.note.hasPrefix("duplicate of ") { duplicateOf[v.key] = String(v.note.dropFirst("duplicate of ".count)) }
        var ok = true
        let clusters = Set(bundled.temperature.clusters.keys).union(calibrated.temperature.clusters.keys).sorted()
        for cluster in clusters {
            let a = expand(bundled.temperature.clusters[cluster] ?? [], bundled)
            let b = expand(calibrated.temperature.clusters[cluster] ?? [], calibrated)
            let missing = a.subtracting(b).sorted()
            let extra = b.subtracting(a).sorted()
            ok = ok && missing.isEmpty
            print(
                "  \(cluster) 温度：\(missing.isEmpty ? "召回完整" : "有遗漏")（内置 \(a.count) 个全部找回：\(missing.isEmpty ? "是" : "否")"
                    + (missing.isEmpty ? "" : "，缺 \(missing.joined(separator: " "))")
                    + (extra.isEmpty ? "" : "；候选 \(extra.count) 个，需人工确认：\(extra.joined(separator: " "))") + "）")
        }
        let railClusters = Set(bundled.power.clusterRails.keys).union(calibrated.power.clusterRails.keys).sorted()
        for cluster in railClusters {
            let a = Set(bundled.power.clusterRails[cluster] ?? [])
            let b = Set((calibrated.power.clusterRails[cluster] ?? []).flatMap { kept in
                [kept] + duplicateOf.filter { $0.value == kept }.map(\.key)
            })
            let missing = a.subtracting(b).sorted()
            let extra = Set(calibrated.power.clusterRails[cluster] ?? []).subtracting(a).filter { k in !a.contains { duplicateOf[$0] == k } }.sorted()
            ok = ok && missing.isEmpty
            print(
                "  \(cluster) 功耗轨：\(missing.isEmpty ? "找回" : "有遗漏") 内置 \(a.sorted()) / 校准 \(calibrated.power.clusterRails[cluster] ?? [])"
                    + (extra.isEmpty ? "" : "；候选 \(extra)"))
        }
        let sentinelsMissing = Set(bundled.temperature.sentinels).subtracting(calibrated.temperature.sentinels)
        ok = ok && sentinelsMissing.isEmpty
        print("  占位值：内置 \(bundled.temperature.sentinels) / 校准 \(calibrated.temperature.sentinels)"
            + (sentinelsMissing.isEmpty ? "" : "；缺 \(sentinelsMissing.sorted())"))
        return ok
    }
}
