// 应用活动窗口的全表（D67，应用活动设计 §1.4、§3.1）：把 AppSampler 的一个窗口变成每个 coalition 一行。
//
// - 身份按 cid 缓存（名字、.app 路径、身份键、代表 pid），只解析新出现的 cid；cid 在一次开机内不复用。
//   窗口首次打开时冷解析一次全部（M5 约 +5.5 ms、M4 约 +9 ms），之后稳态只剩扫描本身；
// - 代表成员与名字的规则同 Top N（`TopNBuilder.representative`、`resolveName`），身份键同 `AppIdentityResolver`；
// - 功率 = 槽位 11 + 41 + 39 的差分 ÷ 窗口（D67），CPU 能耗槽不可信（自检 S4）时为 nil；
// - 宿主 coalition 的副标题（占用最高的成员）由调用方用 Top N 的结果补上（只对 CPU 前几名做，不为全表量 rusage）；
// - 电源断言按 coalition 挂到行上。
// 同一时刻只由一个调用方使用（AppActivityModel 的后台任务串行调用）。

import Darwin
import Foundation
import Synchronization
import SysModel

public final class AppActivityBuilder: Sendable {
    struct Resolved: Hashable, Sendable {
        var key: String
        var name: String
        var appPath: String?
        var representativePID: Int32
    }

    private struct State {
        var byCoalition: [UInt64: Resolved] = [:]
        var bundleIDs: [String: String?] = [:]
    }

    private let state = Mutex(State())
    static let cacheLimit = 8192

    public init() {}

    /// 由窗口生成全表。`assertions` 为同一时刻读到的电源断言（D69）；nil 表示不显示。
    public func build(window: AppActivityWindow, assertions: PowerAssertionSnapshot?) -> AppActivitySnapshot {
        let elapsed = Double(window.elapsedNanos)
        let seconds = elapsed / 1e9
        let resolved = resolve(window.coalitions.map { ($0.id, $0.tasks) })
        var byCoalition: [UInt64: [PowerAssertion]] = [:]
        for assertion in assertions?.assertions ?? [] {
            guard let id = assertion.coalitionID else { continue }
            byCoalition[id, default: []].append(assertion)
        }
        var rows: [AppActivityRow] = []
        rows.reserveCapacity(window.coalitions.count)
        for delta in window.coalitions {
            guard let identity = resolved[delta.id], seconds > 0 else { continue }
            let trusted = window.slotsTrusted
            let watts = Double(delta.energyNanojoules &+ delta.gpuEnergyNanojoules &+ delta.aneEnergyNanojoules) / 1e9 / seconds
            rows.append(
                AppActivityRow(
                    id: "c\(delta.id)", key: identity.key, name: identity.name, appPath: identity.appPath,
                    isApp: identity.appPath != nil, coalitionID: delta.id, representativePID: identity.representativePID,
                    memberCount: Int(delta.tasks), cpu: Double(delta.cpuNanos) / elapsed, cpuTimeNanos: delta.cpuTotalNanos,
                    watts: trusted ? watts : nil, gpuShare: Double(delta.gpuNanos) / elapsed,
                    aneWatts: Double(delta.aneEnergyNanojoules) / 1e9 / seconds,
                    diskRead: Double(delta.diskReadBytes) / seconds, diskWrite: Double(delta.diskWrittenBytes) / seconds,
                    wakeups: Double(delta.wakeups) / seconds, pageins: Double(delta.pageins) / seconds,
                    perfLevel0Share: trusted && delta.cpuNanos > 0 ? Double(delta.perfLevel0Nanos) / Double(delta.cpuNanos) : nil,
                    footprint: delta.footprintBytes, assertions: byCoalition[delta.id] ?? []))
        }
        return AppActivitySnapshot(
            time: window.time.wallClock, seconds: seconds, rows: rows,
            totalWatts: window.slotsTrusted && seconds > 0 ? Double(window.totalEnergyNanojoules) / 1e9 / seconds : nil,
            slotsTrusted: window.slotsTrusted)
    }

    /// 解析一批 coalition 的身份：已缓存的直接返回，其余共用一次进程表快照。解析不到（已退出）的不返回。
    func resolve(_ coalitions: [(id: UInt64, tasks: UInt32)]) -> [UInt64: Resolved] {
        var out: [UInt64: Resolved] = [:]
        var missing: [(id: UInt64, tasks: UInt32)] = []
        state.withLock { s in
            for c in coalitions {
                if let hit = s.byCoalition[c.id] { out[c.id] = hit } else { missing.append(c) }
            }
        }
        guard !missing.isEmpty else { return out }
        let table = ProcessTable.snapshot()
        var resolved: [UInt64: Resolved] = [:]
        for c in missing {
            guard let pids = CoalitionReader.members(of: c.id, tasksHint: Int(c.tasks)), !pids.isEmpty else { continue }
            if pids.contains(0) {
                resolved[c.id] = Resolved(key: AppIdentity.kernel.key, name: AppIdentity.kernel.name, appPath: nil, representativePID: 0)
                continue
            }
            let infos = pids.compactMap { pid -> (ProcessEntry, TopNBuilder.NameInfo)? in
                guard let entry = table[pid] else { return nil }
                return (entry, TopNBuilder.resolveName(path: ProcessInfoReader.path(of: pid), command: entry.command, pid: pid))
            }
            guard let rep = TopNBuilder.representative(infos) else { continue }
            resolved[c.id] = Resolved(
                key: key(for: rep.1, command: rep.0.command), name: rep.1.name, appPath: rep.1.appPath,
                representativePID: rep.0.pid)
        }
        state.withLock { s in
            if s.byCoalition.count + resolved.count > Self.cacheLimit { s.byCoalition.removeAll(keepingCapacity: true) }
            s.byCoalition.merge(resolved) { _, new in new }
        }
        return out.merging(resolved) { _, new in new }
    }

    /// 身份键：同 `AppIdentityResolver`（bundle id → 可执行文件路径 → `comm:`）。
    private func key(for info: TopNBuilder.NameInfo, command: String) -> String {
        if let app = info.appPath {
            let bundleID: String? = state.withLock { s in
                if let cached = s.bundleIDs[app] { return cached }
                let id = Bundle(path: app)?.bundleIdentifier
                s.bundleIDs[app] = id
                return id
            }
            return bundleID ?? app
        }
        if let path = info.path { return path }
        return "comm:" + (command.isEmpty ? info.name : command)
    }
}
