// 传感器校准的分析部分（CPU 模块设计 §5.5，D33）。纯函数，单测覆盖；方法移植自
// research/probes/cpu-module/skeptic-thermal-power/m4_attrib2.py、m4_sentinel.py，并做了通用化：
//
// 1. 占位值：同一个整数值在 ≥3 个键里各自反复出现（≥10 次且 ≥10% 的样本），就是全局占位值（M4：40.0、-4.0、0.0）。
//    温度键的有效样本 = 不是占位值、在 5–130 °C 之间。
// 2. 别名：两个温度键在共同有效样本上差值的标准差 <0.05 °C，即恒等或恒定偏移（M4 三元组的 x0/x1、M5 的 Tm0y=Tp0a）。
//    别名组里取均值最高的一个作代表（三元组里就是 x1）。
// 3. 归簇（阶跃证据）：相邻两段尾部 2 s 的均值之差，ΔT ≈ Σ 组敏感度 × Δ占用，最小二乘。
//    - 同一档里占用变化总是一致的簇合成一组（调度器从不单独加载它们，例如 M4 的两个 P 簇来回切换）：
//      这种簇的温度键分不出归属，归到整组（每个成员簇都列出这些键），不硬分；
//      2026-10-15 复核：调研 §9.3 用乒乓方波把 M4 的 P 键分成 P0/P1 两组，是混用不同滞后的假象，见设计偏离记录；
//    - 判入：拟合 R² ≥ 0.5、最大敏感度 ≥ 1 °C、领先第二组 2 倍以上、GPU 段温升 < 0.65 × 该敏感度（边界稿 §7.3）；
//      GPU 段里没有有效读数（断电占位）视为没有 GPU 证据，不据此排除；
//    - 主导组明确但 GPU 判据不过：若该组没有任何判入的键，记为「附近」读数（只进诊断页，D33），否则排除；
//    - 有响应但没有主导组：排除（SoC 热点等）。
// 4. 峰值变体：三元组结构 (x0, x1, x2) 中，x0/x1 是别名、x2 的键码紧跟 x1，且 x2 几乎总是 ≥ x1 → x2 只作峰值。
// 5. 功耗轨：非温度键对平滑后的各簇占用和 GPU 开关做最小二乘（不做高通，功率是即时的）。
//    只对一个簇有明显响应、对 GPU 没有响应的是该簇的专用轨；只对 GPU 有响应的是 GPU 轨；两者都有的是共享轨。

import Foundation
import SysModel

/// 一次校准的原始记录。只有键名、数值和簇键，没有设备唯一标识，可以存档离线分析。
public struct CalibrationRecording: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable {
        /// 距开始的秒数。
        public var t: Double
        public var phase: String
        /// 每簇占用 0…1，顺序与 `clusters` 相同；读不到时为 nil。
        public var utilization: [Double?]
        public var gpuOn: Bool
        /// 每个键的读数，顺序与 `keys` 相同；读失败时为 nil。
        public var values: [Double?]
    }

    public var socID: String?
    public var osBuild: String?
    public var modelIdentifier: String?
    public var topology: CPUTopology
    public var clusters: [ClusterKey]
    public var keys: [String]
    public var rows: [Row]
}

/// 一个键的分析结论（报告用）。
public struct CalibrationKeyVerdict: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case cluster, nearby, peak, alias, excluded, silent
        case clusterRail, gpuRail, sharedRail
    }

    public var key: String
    public var kind: Kind
    public var cluster: ClusterKey?
    /// 对各簇的敏感度（温度键为 °C / 满载，功耗轨为 W / 满载），顺序与 `CalibrationRecording.clusters` 相同。
    public var sensitivities: [Double]
    public var gpuSensitivity: Double
    public var r2: Double
    public var note: String
}

public struct CalibrationResult: Hashable, Sendable {
    public var profile: ChipProfile
    public var verdicts: [CalibrationKeyVerdict]
    public var sentinels: [Double]
}

public enum CalibrationAnalysis {
    /// 有效温度范围。下限 10 °C：刚上电时会读到 1–5 °C 的瞬态值（2026-10-15 M4 实测）。
    static let validTemperature: ClosedRange<Double> = 10...125
    static let taus: [Double] = [1, 2, 4]
    static let highPassHalfWindow = 6  // 样本数；2 Hz 下为 ±3 s

    public static func analyze(_ rec: CalibrationRecording, socID: String, description: String, build: String?)
        -> CalibrationResult
    {
        let n = rec.rows.count
        let columns = rec.keys.indices.map { k in rec.rows.map { $0.values[k] } }
        let isTemperature = rec.keys.map { $0.hasPrefix("T") }
        let sentinels = detectSentinels(columns: columns, isTemperature: isTemperature, rowCount: n)

        // 有效温度样本
        let temps: [[Double?]] = columns.enumerated().map { k, col in
            guard isTemperature[k] else { return col }
            return col.map { v in v.flatMap { sentinels.contains($0) || !validTemperature.contains($0) ? nil : $0 } }
        }
        let utilization = rec.clusters.indices.map { c in rec.rows.map { $0.utilization[c] ?? 0 } }
        let gpu = rec.rows.map { $0.gpuOn ? 1.0 : 0.0 }
        let dt = n > 1 ? (rec.rows[n - 1].t - rec.rows[0].t) / Double(n - 1) : 0.5

        var verdicts: [String: CalibrationKeyVerdict] = [:]

        // 功耗轨（先做：温度归簇要用各簇功率作自变量）
        var railCandidates: [ClusterKey: [(k: Int, r2: Double)]] = [:]
        var gpuRails: [String] = []
        var sharedRails: [String] = []
        for k in rec.keys.indices where !isTemperature[k] {
            let col = columns[k]
            guard validCount(col) >= 20, variance(col) > 0.01, col.allSatisfy({ ($0 ?? 0) >= 0 && ($0 ?? 0) < 1000 }) else {
                continue
            }
            let fit = bestFit(target: col, utilization: utilization, gpu: gpu, dt: dt, highPass: false)
            let (top, second) = topTwo(fit.cluster)
            let b = top.map { fit.cluster[$0] } ?? 0
            var kind = CalibrationKeyVerdict.Kind.silent
            var cluster: ClusterKey?
            if fit.r2 >= 0.6 {
                if let top, b >= 0.3, second <= 0.15 * b, fit.gpu <= max(0.3, 0.1 * b) {
                    kind = .clusterRail
                    cluster = rec.clusters[top]
                    railCandidates[rec.clusters[top], default: []].append((k, fit.r2))
                } else if fit.gpu >= 1, b <= 0.2 * fit.gpu {
                    kind = .gpuRail
                    gpuRails.append(rec.keys[k])
                } else if fit.gpu >= 1, b >= 0.3 {
                    kind = .sharedRail
                    sharedRails.append(rec.keys[k])
                }
            }
            verdicts[rec.keys[k]] = CalibrationKeyVerdict(
                key: rec.keys[k], kind: kind, cluster: cluster, sensitivities: fit.cluster, gpuSensitivity: fit.gpu,
                r2: fit.r2, note: "")
        }

        // 去重：同一簇的候选轨里，量级相近（0.5–2 倍）且高度相关（>0.85）的是同一路电的重复测量（M5/M4 的 PP*b 与 RP*），
        // 只留拟合最好的一个，避免相加时算重；量级差很多的小轨（如 RP01）照常保留。
        var clusterRails: [ClusterKey: [String]] = [:]
        for (cluster, candidates) in railCandidates {
            // 重复组：量级相近（0.5–2 倍）且高度相关（>0.85）的候选连成一组。
            var parent = Array(candidates.indices)
            func find(_ x: Int) -> Int { parent[x] == x ? x : find(parent[x]) }
            for i in candidates.indices {
                for j in candidates.indices where j > i {
                    let ratio = mean(columns[candidates[i].k]) / max(mean(columns[candidates[j].k]), 1e-9)
                    if (0.5...2).contains(ratio), correlation(columns[candidates[i].k], columns[candidates[j].k]) > 0.85 {
                        parent[find(j)] = find(i)
                    }
                }
            }
            var components: [Int: [Int]] = [:]
            for i in candidates.indices { components[find(i), default: []].append(i) }
            var kept: [String] = []
            for members in components.values {
                // 量级差超过 15% 时留最小的（大的那个多半还包含了别的部件，如 M4 的 PPMR ≈ 1.3 × RP00）；
                // 量级接近时是同一路电的两种测量（PP*b 与 RP*），留拟合最好的。
                let means = members.map { mean(columns[candidates[$0].k]) }
                let spread = (means.max() ?? 0) / max(means.min() ?? 1, 1e-9)
                let pick =
                    spread > 1.15
                    ? members.min { mean(columns[candidates[$0].k]) < mean(columns[candidates[$1].k]) }!
                    : members.max { (candidates[$0].r2, rec.keys[candidates[$1].k]) < (candidates[$1].r2, rec.keys[candidates[$0].k]) }!
                kept.append(rec.keys[candidates[pick].k])
                for m in members where m != pick {
                    verdicts[rec.keys[candidates[m].k]]?.kind = .silent
                    verdicts[rec.keys[candidates[m].k]]?.note = "duplicate of \(rec.keys[candidates[pick].k])"
                }
            }
            clusterRails[cluster] = kept.sorted()
        }

        // 归簇用的自变量：各簇专用轨功率之和（W，按每瓦比较，边界稿 §7.3 第 5 步）；有簇缺专用轨时退回占用。
        let clusterPower: [[Double]]? = rec.clusters.allSatisfy({ !(clusterRails[$0] ?? []).isEmpty })
            ? rec.clusters.map { c in
                let ks = clusterRails[c]!.compactMap { rec.keys.firstIndex(of: $0) }
                return rec.rows.indices.map { i in ks.reduce(0) { $0 + (columns[$1][i] ?? 0) } }
            } : nil
        let drive = clusterPower ?? utilization

        // 温度键：先做别名，再对代表做归簇
        let tempKeys = rec.keys.indices.filter { isTemperature[$0] && variance(temps[$0]) > 0.25 && validCount(temps[$0]) >= 20 }
        let aliasGroups = detectAliases(keys: tempKeys, columns: temps)
        var representative: [Int: Int] = [:]
        for group in aliasGroups {
            let rep = group.max { mean(temps[$0]) < mean(temps[$1]) }!
            for k in group { representative[k] = rep }
        }
        for k in rec.keys.indices where isTemperature[k] && !tempKeys.contains(k) {
            verdicts[rec.keys[k]] = CalibrationKeyVerdict(
                key: rec.keys[k], kind: .silent, cluster: nil, sensitivities: [], gpuSensitivity: 0, r2: 0,
                note: "no valid variation")
        }
        // 阶跃证据：相邻两段（都不是 GPU 段）尾部 2 s 均值之差。同一档里各簇占用变化总是一致的簇
        // （调度器从不单独加载它们，例如 M4 的两个 P 簇来回切换）合成一组，键归到整组，不硬分。
        let steps = stepEvidence(rec, drive: drive, sentinels: sentinels)
        let groups = clusterGroups(rec, steps: steps)
        var clusterKeys: [ClusterKey: [String]] = [:]
        var pendingNearby: [(String, [ClusterKey])] = []
        var gpuRatio: [Int: Double] = [:]
        for k in tempKeys where representative[k] == nil || representative[k] == k {
            let key = rec.keys[k]
            guard let fit = stepFit(key: k, steps: steps, groups: groups, clusters: rec.clusters) else {
                verdicts[key] = CalibrationKeyVerdict(
                    key: key, kind: .silent, cluster: nil, sensitivities: [], gpuSensitivity: 0, r2: 0,
                    note: "too few steps with valid readings")
                continue
            }
            // 满载贡献（°C）= 敏感度 × 该组自变量的最大值：判断「这是不是这个组的温度」。
            // 每瓦敏感度：只用来给「附近」读数定位（低功耗的簇每瓦敏感度会被放大，不能用来判归属）。
            let peaksOfGroups = groups.map { groupPeak($0, drive: drive, clusters: rec.clusters) }
            let contribution = zip(fit.group, peaksOfGroups).map { $0 * $1 }
            let (top, second) = topTwo(contribution)
            let cTop = top.map { contribution[$0] } ?? 0
            let nearest = topTwo(fit.group).top
            let members = top.map { groups[$0] } ?? []
            let gpuDelta = gpuStep(key: k, rec: rec, sentinels: sentinels)
            var kind = CalibrationKeyVerdict.Kind.excluded
            var note = ""
            if wakesWithGPU(key: k, rec: rec, sentinels: sentinels) {
                note = "power-gated when idle, readable under GPU load: GPU domain"
            } else if fit.r2 < 0.5 || cTop < 1.0 {
                kind = .silent
                note = "weak response"
            } else if let top, cTop >= 1.5 * max(second, 0), !(gpuDelta.map { $0 >= cTop } ?? false) {
                kind = .cluster
                for c in groups[top] { clusterKeys[c, default: []].append(key) }
                if let g = gpuDelta { gpuRatio[k] = g / cTop }
                note = groups[top].count > 1 ? "shared by \(groups[top].map(\.description).joined(separator: "+"))" : ""
            } else {
                if let g = gpuDelta, g >= cTop {
                    note = "GPU step \(round2(g)) ≥ full-load \(round2(cTop))"
                } else {
                    note = "no dominant cluster (full-load \(contribution.map(round2)))"
                }
                if let nearest { pendingNearby.append((key, groups[nearest])) }
            }
            let perCluster = rec.clusters.map { c in groups.firstIndex { $0.contains(c) }.map { fit.group[$0] } ?? 0 }
            verdicts[key] = CalibrationKeyVerdict(
                key: key, kind: kind, cluster: members.count == 1 ? members[0] : members.first,
                sensitivities: perCluster, gpuSensitivity: gpuDelta ?? .nan, r2: fit.r2, note: note)
        }
        // GPU 判据按同组比较：GPU 段会让整片芯片一起升温，短负载下绝对比值不稳（M5 两次实测，GPU 段在前时
        // M 簇的键 GPU/满载 ≈ 0.7–0.8）。只排除比同组中位数高 2 倍以上、且超过 0.65 的键（相对 GPU 格外敏感）。
        for (cluster, keys) in clusterKeys {
            let ratios = keys.compactMap { rec.keys.firstIndex(of: $0) }.compactMap { gpuRatio[$0] }
            guard ratios.count >= 3 else { continue }
            let typical = median(ratios)
            for key in keys {
                guard let k = rec.keys.firstIndex(of: key), let r = gpuRatio[k], r > 0.65, r > 2 * typical else { continue }
                clusterKeys[cluster]?.removeAll { $0 == key }
                verdicts[key]?.kind = .excluded
                verdicts[key]?.note = "GPU-sensitive vs. peers: \(round2(r)) > 2 × median \(round2(typical))"
            }
        }

        // 聚合键与热点离群：判入之后逐组复核（边界稿 §7.3 第 4 步，2026-10-15 两台实测）。
        let aggregates = detectAggregates(keys: tempKeys, columns: temps, aliasGroups: aliasGroups)
        for (cluster, keys) in clusterKeys {
            let loadedRows = rec.rows.indices.filter { rec.rows[$0].phase.hasPrefix("ui") }
            let outliers = hotOutliers(keys.compactMap { rec.keys.firstIndex(of: $0) }, columns: temps, rows: loadedRows)
            for key in keys {
                guard let k = rec.keys.firstIndex(of: key) else { continue }
                if aggregates.contains(k) {
                    clusterKeys[cluster]?.removeAll { $0 == key }
                    verdicts[key]?.kind = .excluded
                    verdicts[key]?.note = "aggregate: equals another key's reading row by row"
                } else if outliers.contains(k) {
                    clusterKeys[cluster]?.removeAll { $0 == key }
                    verdicts[key]?.kind = .excluded
                    verdicts[key]?.note = "hot outlier: far above the cluster's other keys"
                }
            }
        }
        clusterKeys = clusterKeys.filter { !$0.value.isEmpty }

        var nearby: [ClusterKey: [String]] = [:]
        for (key, members) in pendingNearby where members.allSatisfy({ clusterKeys[$0] == nil }) {
            for c in members { nearby[c, default: []].append(key) }
            verdicts[key]?.kind = .nearby
        }
        for group in aliasGroups {
            guard let rep = group.first.flatMap({ representative[$0] }) else { continue }
            for k in group where k != rep {
                verdicts[rec.keys[k]] = CalibrationKeyVerdict(
                    key: rec.keys[k], kind: .alias, cluster: verdicts[rec.keys[rep]]?.cluster, sensitivities: [],
                    gpuSensitivity: 0, r2: 0, note: "alias of \(rec.keys[rep])")
            }
        }

        // 峰值变体（三元组的 x2）：从它所在组的每个簇里移出，归为这些簇的峰值。
        var peaks: [ClusterKey: [String]] = [:]
        for group in aliasGroups where group.count == 2 {
            let rep = representative[group[0]]!
            guard let repCode = SMCKey(fourCC: rec.keys[rep])?.code,
                let next = rec.keys.firstIndex(where: { SMCKey(fourCC: $0)?.code == repCode + 1 }),
                isPeak(temps[next], over: temps[rep])
            else { continue }
            let key = rec.keys[next]
            let members = clusterKeys.filter { $0.value.contains(rec.keys[rep]) || $0.value.contains(key) }.keys
            guard !members.isEmpty else { continue }
            for c in members {
                clusterKeys[c]?.removeAll { $0 == key }
                peaks[c, default: []].append(key)
            }
            verdicts[key]?.kind = .peak
            verdicts[key]?.note = "≥ \(rec.keys[rep]) almost always"
        }

        let excluded = verdicts.values.filter { $0.kind == .excluded }.map(\.key).sorted()
        let profile = ChipProfile(
            socID: socID, description: description, verifiedBuilds: build.map { [$0] } ?? [],
            source: "sysinfo-cli calibrate (\(rec.modelIdentifier ?? "?"), build \(build ?? "?"), \(rec.rows.count) samples)",
            topology: TopologyExpectation(
                cpuCountsByLevel: rec.topology.perfLevels.map(\.cpuCount),
                clusterLevels: Dictionary(
                    uniqueKeysWithValues: rec.topology.clusters.compactMap { c in c.perfLevel.map { (c.key.description, $0) } })),
            temperature: TemperatureProfile(
                clusters: stringKeyed(clusterKeys), aliasGroups: aliasGroups.map { $0.map { rec.keys[$0] }.sorted() },
                peaks: stringKeyed(peaks), nearby: stringKeyed(nearby), excluded: excluded,
                sentinels: sentinels.sorted(), validRange: [validTemperature.lowerBound, validTemperature.upperBound]),
            power: PowerProfile(clusterRails: stringKeyed(clusterRails), gpuRails: gpuRails.sorted(), sharedRails: sharedRails.sorted()))
        return CalibrationResult(
            profile: profile, verdicts: verdicts.values.sorted { $0.key < $1.key }, sentinels: sentinels.sorted())
    }

    // MARK: - 步骤

    static func detectSentinels(columns: [[Double?]], isTemperature: [Bool], rowCount: Int) -> Set<Double> {
        var keysPerValue: [Double: Int] = [:]
        for (k, col) in columns.enumerated() where isTemperature[k] {
            var counts: [Double: Int] = [:]
            for v in col.compactMap({ $0 }) where v == v.rounded() && abs(v) <= 100 { counts[v, default: 0] += 1 }
            for (v, c) in counts where c >= 10 && Double(c) >= 0.1 * Double(rowCount) { keysPerValue[v, default: 0] += 1 }
        }
        return Set(keysPerValue.filter { $0.value >= 3 }.keys)
    }

    static func detectAliases(keys: [Int], columns: [[Double?]]) -> [[Int]] {
        var parent = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x]! != x { x = parent[x]! }
            return x
        }
        for (i, a) in keys.enumerated() {
            for b in keys[(i + 1)...] {
                var diffs: [Double] = []
                for (x, y) in zip(columns[a], columns[b]) { if let x, let y { diffs.append(y - x) } }
                guard diffs.count >= 20, stddev(diffs) < 0.05 else { continue }
                parent[find(b)] = find(a)
            }
        }
        var groups: [Int: [Int]] = [:]
        for k in keys { groups[find(k), default: []].append(k) }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    static func isPeak(_ candidate: [Double?], over base: [Double?]) -> Bool {
        var diffs: [Double] = []
        for (x, y) in zip(base, candidate) { if let x, let y { diffs.append(y - x) } }
        guard diffs.count >= 20 else { return false }
        let nonNegative = Double(diffs.filter { $0 >= -0.05 }.count) / Double(diffs.count)
        return nonNegative >= 0.98 && mean(diffs.map(Optional.some)) > 0.3 && stddev(diffs) >= 0.05
    }

    struct Fit {
        var cluster: [Double]
        var gpu: Double
        var r2: Double
    }

    /// 在几档平滑时间常数里取拟合最好的一个。
    static func bestFit(target: [Double?], utilization: [[Double]], gpu: [Double], dt: Double, highPass: Bool) -> Fit {
        var best = Fit(cluster: utilization.map { _ in 0 }, gpu: 0, r2: -1)
        for tau in taus {
            let features = utilization.map { ema($0, tau: tau, dt: dt) } + [ema(gpu, tau: tau, dt: dt)]
            guard let fit = leastSquares(target: target, features: features, highPass: highPass) else { continue }
            if fit.r2 > best.r2 { best = fit }
        }
        return best
    }

    static func leastSquares(target: [Double?], features: [[Double]], highPass: Bool) -> Fit? {
        let n = target.count
        let w = highPassHalfWindow
        var rows: [[Double]] = []
        var ys: [Double] = []
        for i in 0..<n {
            guard let y = target[i] else { continue }
            if highPass {
                guard i >= w, i + w < n else { continue }
                let window = target[(i - w)...(i + w)]
                guard window.allSatisfy({ $0 != nil }) else { continue }
                let m = window.reduce(0) { $0 + $1! } / Double(window.count)
                rows.append(features.map { f in f[i] - f[(i - w)...(i + w)].reduce(0, +) / Double(2 * w + 1) })
                ys.append(y - m)
            } else {
                rows.append([1] + features.map { $0[i] })
                ys.append(y)
            }
        }
        let p = rows.first?.count ?? 0
        guard rows.count >= max(20, 3 * p), p > 0 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var b = [Double](repeating: 0, count: p)
        for (row, y) in zip(rows, ys) {
            for i in 0..<p {
                b[i] += row[i] * y
                for j in 0..<p { a[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<p { a[i][i] += 1e-9 }  // 某个特征恒为 0（例如没跑 GPU 段）时避免奇异
        guard let coef = solve(a, b) else { return nil }
        let pred = rows.map { zip($0, coef).reduce(0) { $0 + $1.0 * $1.1 } }
        let my = ys.reduce(0, +) / Double(ys.count)
        let ssTot = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        let ssRes = zip(ys, pred).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0
        let offset = highPass ? 0 : 1
        let clusterCount = features.count - 1
        return Fit(
            cluster: Array(coef[offset..<(offset + clusterCount)]), gpu: coef[offset + clusterCount], r2: r2)
    }

    // MARK: - 阶跃证据

    struct Step {
        /// 每簇自变量的变化（后一段尾部 − 前一段尾部）：功率（W）或占用。
        var du: [Double]
        /// 每簇占用的变化（分组判断只看占用）。
        var dUtil: [Double]
        /// 每个键的温度变化；两段尾部里有一段没有有效读数时为 nil。
        var dT: [Double?]
    }

    /// 连续的同名样本段：(段名, 起点, 终点)。
    static func segments(_ rec: CalibrationRecording) -> [(name: String, gpu: Bool, range: ClosedRange<Int>)] {
        var out: [(String, Bool, ClosedRange<Int>)] = []
        for (i, row) in rec.rows.enumerated() {
            if let last = out.last, last.0 == row.phase, last.2.upperBound == i - 1 {
                out[out.count - 1].2 = last.2.lowerBound...i
            } else {
                out.append((row.phase, row.gpuOn, i...i))
            }
        }
        return out
    }

    static let tailSamples = 6  // 2 Hz 下为段尾 3 s：盖过 M4 乒乓的一个周期，乒乓段的两簇占用都接近 0.5

    static func tail(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
        max(range.lowerBound, range.upperBound - tailSamples + 1)...range.upperBound
    }

    static func stepEvidence(_ rec: CalibrationRecording, drive: [[Double]], sentinels: Set<Double>) -> [Step] {
        let segs = segments(rec)
        func tailMean(_ range: ClosedRange<Int>, _ value: (Int) -> Double?) -> Double? {
            let v = tail(range).compactMap(value)
            return v.count >= 2 ? v.reduce(0, +) / Double(v.count) : nil
        }
        var steps: [Step] = []
        for (a, b) in zip(segs, segs.dropFirst()) where !a.gpu && !b.gpu {
            let du = rec.clusters.indices.map { c in
                (tailMean(b.range) { drive[c][$0] } ?? 0) - (tailMean(a.range) { drive[c][$0] } ?? 0)
            }
            let dUtil = rec.clusters.indices.map { c in
                (tailMean(b.range) { rec.rows[$0].utilization[c] } ?? 0) - (tailMean(a.range) { rec.rows[$0].utilization[c] } ?? 0)
            }
            let dT = rec.keys.indices.map { k -> Double? in
                guard let x = tailMean(a.range, { validTemperatureValue(rec.rows[$0].values[k], sentinels) }),
                    let y = tailMean(b.range, { validTemperatureValue(rec.rows[$0].values[k], sentinels) })
                else { return nil }
                return y - x
            }
            steps.append(Step(du: du, dUtil: dUtil, dT: dT))
        }
        return steps
    }

    /// 同档的两个簇，只有在至少 2 次阶跃里「一个满、一个空」（占用变化相差 ≥0.8）才分开；否则合成一组。
    /// 不同档的簇从不合并。M5 的两个 M 簇会被依次填满，可以分开；M4 的两个 P 簇来回切换，合成一组。
    static func clusterGroups(_ rec: CalibrationRecording, steps: [Step]) -> [[ClusterKey]] {
        let level = rec.clusters.map { c in rec.topology.clusters.first { $0.key == c }?.perfLevel ?? -1 }
        var parent = Array(rec.clusters.indices)
        func find(_ x: Int) -> Int { parent[x] == x ? x : find(parent[x]) }
        for i in rec.clusters.indices {
            for j in rec.clusters.indices where j > i && level[i] == level[j] {
                let separating = steps.filter { abs($0.dUtil[i] - $0.dUtil[j]) >= 0.8 }.count
                if separating < 2 { parent[find(j)] = find(i) }
            }
        }
        var groups: [Int: [ClusterKey]] = [:]
        for i in rec.clusters.indices { groups[find(i), default: []].append(rec.clusters[i]) }
        return groups.keys.sorted().map { groups[$0]! }
    }

    struct StepFit {
        /// 每组的敏感度（°C / 满载变化）。
        var group: [Double]
        var r2: Double
    }

    /// ΔT ≈ c + Σ_组 s × Δx（组内取各簇 Δx 的平均）。常数项 c 吸收每一步里持续升温的漂移：
    /// 计划是先升后降的对称阶跃，漂移在升、降两步里同号，组的贡献异号，所以能分开（M4 的 E 簇只在 P 满载期间单独变化）。
    /// 有效的阶跃数不够（< 自变量数 + 2）时返回 nil。
    static func stepFit(key k: Int, steps: [Step], groups: [[ClusterKey]], clusters: [ClusterKey]) -> StepFit? {
        let index = Dictionary(uniqueKeysWithValues: clusters.enumerated().map { ($1, $0) })
        var rows: [[Double]] = []
        var ys: [Double] = []
        for step in steps {
            guard let dT = step.dT[k] else { continue }
            rows.append(groups.map { members in
                members.reduce(0) { $0 + step.du[index[$1]!] } / Double(members.count)
            })
            ys.append(dT)
        }
        let p = groups.count
        // 只保留在这些阶跃里确实变化过的组，其余组的敏感度记为 0。
        let active = (0..<p).filter { g in (rows.map { abs($0[g]) }.max() ?? 0) > 1e-6 }
        guard !active.isEmpty, rows.count >= active.count + 2 else { return nil }
        let q = active.count + 1  // 末位是常数项
        var a = [[Double]](repeating: [Double](repeating: 0, count: q), count: q)
        var bvec = [Double](repeating: 0, count: q)
        for (row, y) in zip(rows, ys) {
            let x = active.map { row[$0] } + [1]
            for i in 0..<q {
                bvec[i] += x[i] * y
                for j in 0..<q { a[i][j] += x[i] * x[j] }
            }
        }
        for i in 0..<q { a[i][i] += 1e-9 }
        guard let coef = solve(a, bvec) else { return nil }
        var group = [Double](repeating: 0, count: p)
        for (i, gi) in active.enumerated() { group[gi] = coef[i] }
        let pred = rows.map { row in active.indices.reduce(coef[q - 1]) { $0 + row[active[$1]] * coef[$1] } }
        let my = ys.reduce(0, +) / Double(ys.count)
        let ssTot = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        let ssRes = zip(ys, pred).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        return StepFit(group: group, r2: ssTot > 0 ? 1 - ssRes / ssTot : 0)
    }

    /// 聚合键：几乎每一行（≥90%）都恰好等于另外某个键（差 <0.01 °C），而且对上的键不止一个
    /// （M4 的 Tpx* 是几个键的逐行最大值）。恒等别名不算（它们总是对上同一个键）。
    static func detectAggregates(keys: [Int], columns: [[Double?]], aliasGroups: [[Int]]) -> Set<Int> {
        var out: Set<Int> = []
        let aliasOf = Dictionary(aliasGroups.flatMap { g in g.map { ($0, Set(g)) } }, uniquingKeysWith: { a, _ in a })
        for k in keys {
            var rows = 0
            var matched = 0
            var sources: Set<Int> = []
            for i in columns[k].indices {
                guard let v = columns[k][i] else { continue }
                rows += 1
                if let j = keys.first(where: { $0 != k && !(aliasOf[k]?.contains($0) ?? false) && columns[$0][i].map { abs($0 - v) < 0.01 } ?? false }) {
                    matched += 1
                    sources.insert(j)
                }
            }
            if rows >= 20, Double(matched) >= 0.9 * Double(rows), sources.count >= 2 { out.insert(k) }
        }
        return out
    }

    /// 热点离群：负载段里相对本组逐行中位数的偏移，远高于本组其他键（> Q3 + 3 × IQR）。
    /// 例如 M5 Super 组里的 TVDC/TVDP（+13 °C，核心键最高约 +7 °C）。
    static func hotOutliers(_ members: [Int], columns: [[Double?]], rows: [Int]) -> Set<Int> {
        guard members.count >= 5 else { return [] }
        var offsets: [Int: Double] = [:]
        for k in members {
            var d: [Double] = []
            for i in rows {
                guard let v = columns[k][i] else { continue }
                let others = members.compactMap { columns[$0][i] }
                guard others.count >= 3 else { continue }
                d.append(v - median(others))
            }
            if d.count >= 10 { offsets[k] = median(d) }
        }
        let sorted = offsets.values.sorted()
        guard sorted.count >= 5 else { return [] }
        let q1 = sorted[sorted.count / 4]
        let q3 = sorted[(3 * sorted.count) / 4]
        let fence = q3 + 3 * max(q3 - q1, 0.5)
        return Set(offsets.filter { $0.value > fence }.keys)
    }

    static func median(_ x: [Double]) -> Double {
        let s = x.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 一组簇的自变量（功率或占用之和）在全程的最大值。
    static func groupPeak(_ members: [ClusterKey], drive: [[Double]], clusters: [ClusterKey]) -> Double {
        let index = members.compactMap { clusters.firstIndex(of: $0) }
        guard let n = drive.first?.count else { return 0 }
        return (0..<n).map { i in index.reduce(0) { $0 + drive[$1][i] } / Double(max(index.count, 1)) }.max() ?? 0
    }

    /// CPU 空闲时几乎断电（有效读数 ≤10%）、GPU 段才有读数（≥50%）的键属于 GPU 供电域（M4 的 Tp1*/Tp2*）。
    static func wakesWithGPU(key k: Int, rec: CalibrationRecording, sentinels: Set<Double>) -> Bool {
        let segs = segments(rec)
        func validFraction(_ ranges: [ClosedRange<Int>]) -> Double? {
            let idx = ranges.flatMap { Array($0) }
            guard !idx.isEmpty else { return nil }
            return Double(idx.filter { validTemperatureValue(rec.rows[$0].values[k], sentinels) != nil }.count) / Double(idx.count)
        }
        guard let gpu = validFraction(segs.filter(\.gpu).map(\.range)),
            let idle = validFraction(segs.filter { $0.name == "idle" }.map(\.range))
        else { return false }
        return idle <= 0.1 && gpu >= 0.5
    }

    /// GPU 段的温升：GPU 段尾部 − 前一段尾部。GPU 段里没有有效读数（例如断电占位）时为 nil，即没有证据。
    static func gpuStep(key k: Int, rec: CalibrationRecording, sentinels: Set<Double>) -> Double? {
        let segs = segments(rec)
        guard let g = segs.firstIndex(where: { $0.gpu }), g > 0 else { return nil }
        func tailMean(_ range: ClosedRange<Int>) -> Double? {
            let v = tail(range).compactMap { validTemperatureValue(rec.rows[$0].values[k], sentinels) }
            return v.count >= 2 ? v.reduce(0, +) / Double(v.count) : nil
        }
        guard let before = tailMean(segs[g - 1].range), let during = tailMean(segs[g].range) else { return nil }
        return during - before
    }

    /// 有效温度读数：不是占位值、在有效范围内。
    static func validTemperatureValue(_ v: Double?, _ sentinels: Set<Double>) -> Double? {
        guard let v, validTemperature.contains(v), !sentinels.contains(v) else { return nil }
        return v
    }

    static func correlation(_ x: [Double?], _ y: [Double?]) -> Double {
        var xs: [Double] = []
        var ys: [Double] = []
        for (a, b) in zip(x, y) { if let a, let b { xs.append(a); ys.append(b) } }
        guard xs.count > 2 else { return 0 }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(xs, ys) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }

    // MARK: - 数值工具

    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a.enumerated().map { $0.element + [b[$0.offset]] }
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = m[r][c] / m[c][c]
                if f != 0 { for j in c...n { m[r][j] -= f * m[c][j] } }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }

    static func ema(_ x: [Double], tau: Double, dt: Double) -> [Double] {
        let alpha = 1 - exp(-dt / tau)
        var out: [Double] = []
        out.reserveCapacity(x.count)
        var s = x.first ?? 0
        for v in x {
            s += alpha * (v - s)
            out.append(s)
        }
        return out
    }

    static func topTwo(_ values: [Double]) -> (top: Int?, second: Double) {
        guard let top = values.indices.max(by: { values[$0] < values[$1] }) else { return (nil, 0) }
        let second = values.indices.filter { $0 != top }.map { values[$0] }.max() ?? 0
        return (top, second)
    }

    static func validCount(_ x: [Double?]) -> Int { x.compactMap { $0 }.count }

    static func mean(_ x: [Double?]) -> Double {
        let v = x.compactMap { $0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    static func variance(_ x: [Double?]) -> Double {
        let v = x.compactMap { $0 }
        guard v.count > 1 else { return 0 }
        let m = v.reduce(0, +) / Double(v.count)
        return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
    }

    static func stddev(_ x: [Double]) -> Double { variance(x.map(Optional.some)).squareRoot() }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func stringKeyed(_ map: [ClusterKey: [String]]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.description, $0.value.sorted()) })
    }
}
