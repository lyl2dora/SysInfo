// CPU 模块的诊断状态（CPU 模块设计 §7.4，K19，D33、D37）：被动核对、传感器校准。
//
// - 被动核对（PassiveValidator）吃全部 tick 结果；拓扑变化时重建。有一项不过时让引擎复检，10 分钟内最多一次；
// - 传感器校准只在用户点击并确认后运行（约 58 s，期间 CPU 满载，D18、D19）。在后台线程录制与分析，不占 MainActor。
//   有内置档案的芯片只出核对报告，不覆盖内置档案；没有内置档案的芯片才保存本机校准结果（D37）。

import AppKit
import Observation
import SysCollectors
import SysModel
import OSLog

@Observable
final class CPUDiagnosticsModel {
    /// 各项被动核对的最近结果（按检查代码）。
    private(set) var findings: [String: PassiveFinding] = [:]
    private(set) var calibration: CalibrationState = .idle

    enum CalibrationState {
        case idle
        case running(phase: String, startedAt: Date, totalSeconds: Double)
        case finished(CalibrationReport)
        case failed(String)
    }

    /// 一次校准的结论（文本不含设备唯一标识）。
    struct CalibrationReport {
        var date: Date
        var socID: String
        /// 有内置档案时的比对结果。
        var comparison: CalibrationComparison?
        /// 没有内置档案时保存的位置。
        var savedTo: URL?
        var clusterKeyCounts: [(cluster: String, keys: Int, rails: Int)]
    }

    @ObservationIgnored private var validator: PassiveValidator?
    @ObservationIgnored private var validatorGeneration: UInt64?
    @ObservationIgnored private var lastRecheck: Date?
    @ObservationIgnored var requestSelfTests: () -> Void = {}

    static let recheckInterval: TimeInterval = 600

    func ingest(_ result: TickResult) {
        let service = CPUTopologyService.shared
        guard let topology = service.current, topology.quality.isOK else { return }
        if validatorGeneration != service.generation {
            validator = PassiveValidator(topology: topology)
            validatorGeneration = service.generation
        }
        guard let validator else { return }
        let new = validator.ingest(result)
        guard !new.isEmpty else { return }
        for finding in new { findings[finding.check] = finding }
        if new.contains(where: { !$0.passed }), lastRecheck.map({ Date().timeIntervalSince($0) > Self.recheckInterval }) ?? true {
            lastRecheck = Date()
            Log.app.notice("被动核对未通过，触发复检：\(new.filter { !$0.passed }.map(\.check), privacy: .public)")
            requestSelfTests()
        }
    }

    // MARK: - 校准

    var isCalibrating: Bool {
        if case .running = calibration { return true }
        return false
    }

    /// 用户点击「传感器校准」：先说明负载并确认，再在后台运行。
    func startCalibration() {
        guard !isCalibrating else { return }
        let topology = CPUTopologyService.shared.refresh()
        guard topology.quality.isOK else {
            calibration = .failed(String(localized: "拓扑没有判定出核档，不能校准"))
            return
        }
        let phases = Calibration.plan(for: topology)
        let total = phases.reduce(0) { $0 + $1.seconds }
        let alert = NSAlert()
        alert.messageText = String(localized: "运行传感器校准？")
        alert.informativeText = String(
            localized:
                "约 \(Int(total)) 秒。期间 SysInfo 会让 CPU 各簇轮流满载，并给 GPU 加一段计算负载，风扇可能转起来。请先关掉其他占用高的程序，结果更准。"
        )
        alert.addButton(withTitle: String(localized: "开始"))
        alert.addButton(withTitle: String(localized: "取消"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        calibration = .running(phase: phases.first?.name ?? "", startedAt: Date(), totalSeconds: total)
        Log.app.info("开始传感器校准，约 \(Int(total)) s")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let recording = try Calibration.record(topology: topology, phases: phases) { phase in
                    Task { @MainActor in
                        guard let self, case .running(_, let started, let total) = self.calibration else { return }
                        self.calibration = .running(phase: phase.name, startedAt: started, totalSeconds: total)
                    }
                }
                let report = Self.analyze(recording)
                await MainActor.run { self?.calibration = .finished(report) }
            } catch {
                await MainActor.run { self?.calibration = .failed(String(describing: error)) }
            }
        }
    }

    nonisolated static func analyze(_ recording: CalibrationRecording) -> CalibrationReport {
        let socID = recording.socID ?? "unknown"
        let result = CalibrationAnalysis.analyze(
            recording, socID: socID, description: "\(recording.modelIdentifier ?? "?") (calibrated)", build: recording.osBuild)
        let profile = result.profile
        let counts = recording.clusters.map { c in
            (c.description, profile.temperature.clusters[c.description]?.count ?? 0, profile.power.clusterRails[c.description]?.count ?? 0)
        }
        var report = CalibrationReport(date: Date(), socID: socID, comparison: nil, savedTo: nil, clusterKeyCounts: counts)
        if let bundled = ChipProfileStore.bundledProfiles().first(where: { $0.socID == socID }) {
            // D37：有内置档案时只出核对报告，不覆盖
            report.comparison = CalibrationComparison.compare(bundled: bundled, calibrated: profile, verdicts: result.verdicts)
        } else if let build = recording.osBuild {
            report.savedTo = try? ChipProfileStore.saveCalibration(profile, build: build)
        }
        return report
    }
}
