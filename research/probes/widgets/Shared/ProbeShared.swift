// host 与扩展共用：App Group 位置、快照格式、事件日志、刷新 intent。
import Foundation
import AppIntents
import WidgetKit
import os
import Darwin

let probeLog = Logger(subsystem: "zone.lyl.sysinfo.probe", category: "probe")

enum Probe {
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "ProbeAppGroup") as? String ?? "?" }

    static var groupURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }

    static var role: String { Bundle.main.bundlePath.hasSuffix(".appex") ? "ext" : "host" }

    /// 本进程的 phys_footprint（字节）。
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// 往组容器的 events.jsonl 追加一行，同时打到 os_log。
    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        var f = fields
        f["t"] = Date().timeIntervalSince1970
        f["ev"] = name
        f["role"] = role
        f["pid"] = Int(getpid())
        f["fpMB"] = Double(footprint()) / 1_048_576
        f["sandbox"] = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let line = (try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        probeLog.log("EVENT \(line, privacy: .public)")
        guard let url = groupURL?.appendingPathComponent("events.jsonl") else {
            probeLog.error("EVENT no group container for \(group, privacy: .public)")
            return
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { probeLog.error("EVENT open failed errno=\(errno)"); return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}

struct ProbeSnapshot: Codable {
    var seq: Int
    var writtenAt: Date
    var reason: String
    var points: [Double]
    /// 填充，用来测快照大小的影响。
    var padding: String
    /// 扩展收到后额外分配并触碰这么多 MB，用来找扩展的内存上限。
    var ballastMB: Int

    static var url: URL? { Probe.groupURL?.appendingPathComponent("snapshot.json") }

    static func load() -> (ProbeSnapshot?, Int, Double) {
        guard let url else { return (nil, 0, 0) }
        let t0 = Date()
        guard let data = try? Data(contentsOf: url) else { return (nil, 0, 0) }
        let s = try? JSONDecoder().decode(ProbeSnapshot.self, from: data)
        return (s, data.count, Date().timeIntervalSince(t0) * 1000)
    }

    func save() throws {
        guard let url = Self.url else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// host 写快照：seq 递增，其余参数沿用上一份（除非显式给出）。
    static func bump(reason: String, points: Int? = nil, padKB: Int? = nil, ballastMB: Int? = nil) -> ProbeSnapshot? {
        let old = load().0
        let n = points ?? old?.points.count ?? 60
        let seq = (old?.seq ?? 0) + 1
        let pts = (0..<n).map { i in 50 + 40 * sin(Double(i + seq) / 7) }
        let pad = padKB.map { String(repeating: "x", count: $0 * 1024) } ?? old?.padding ?? ""
        let s = ProbeSnapshot(seq: seq, writtenAt: Date(), reason: reason, points: pts, padding: pad, ballastMB: ballastMB ?? old?.ballastMB ?? 0)
        do {
            try s.save()
            Probe.event("snapshot.write", ["seq": seq, "reason": reason, "points": n, "padKB": pad.utf8.count / 1024, "ballastMB": s.ballastMB])
            return s
        } catch {
            Probe.event("snapshot.write.error", ["error": "\(error)"])
            return nil
        }
    }
}

/// 小组件和 Control 上的刷新按钮。macOS 27 起可以指定在主进程执行（probe C）。
struct ProbeRefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新探针快照"
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult {
        Probe.event("intent.perform")
        if Probe.role == "host" {
            _ = ProbeSnapshot.bump(reason: "intent")
        }
        WidgetCenter.shared.reloadAllTimelines()
        Probe.event("intent.reloadAll")
        return .result()
    }
}

/// 对照：不指定执行目标，系统默认放在哪里执行。
struct ProbeRefreshDefaultIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新探针快照（默认目标）"

    func perform() async throws -> some IntentResult {
        Probe.event("intent.default.perform")
        if Probe.role == "host" {
            _ = ProbeSnapshot.bump(reason: "intent-default")
        }
        return .result()
    }
}
