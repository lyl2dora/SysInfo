// coalition → 应用身份（CPU 模块设计 §6 的每应用分钟数据，D30）。
//
// 历史库按「应用」而不是 coalition 记：coalition id 每次开机都不同，同一个 app 重启后也会换 id。
// 身份键取代表成员所在最外层 .app 的 bundle id，没有 .app 时取可执行文件路径；pid 0 为 kernel_task。
// 代表成员的选法与 Top N 一致（TopNBuilder.coalitionRow）：.app 里的成员优先，同级取最早启动的。
//
// coalition id 在一次开机内不复用，所以按 id 缓存，每个 coalition 只解析一次。
// coalition 在最后一个成员退出时就消失了，解析不到的返回 nil，由调用方决定怎么记。

import Foundation
import Synchronization

/// 一个应用在历史库里的身份。
public struct AppIdentity: Hashable, Sendable, Codable {
    /// 稳定键：bundle id、可执行文件路径，或 `kernel_task`。
    public var key: String
    /// 显示名（解析当时的本地化名字）。
    public var name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    public static let kernel = AppIdentity(key: "kernel_task", name: "kernel_task")
}

public final class AppIdentityResolver: Sendable {
    private struct State {
        var byCoalition: [UInt64: AppIdentity] = [:]
        /// .app 路径 → bundle id（读 Info.plist 有文件 IO，只读一次）。
        var bundleIDs: [String: String?] = [:]
    }

    private let state = Mutex(State())

    /// 缓存上限：超过时整体清空（只会让后面的 coalition 重新解析一次）。
    static let cacheLimit = 4096

    public init() {}

    /// 解析一批 coalition。已缓存的直接返回；其余的共用一次进程表快照。
    public func resolve(_ coalitions: [(id: UInt64, tasks: UInt32)]) -> [UInt64: AppIdentity] {
        var out: [UInt64: AppIdentity] = [:]
        var missing: [(id: UInt64, tasks: UInt32)] = []
        state.withLock { s in
            for c in coalitions {
                if let hit = s.byCoalition[c.id] { out[c.id] = hit } else { missing.append(c) }
            }
        }
        guard !missing.isEmpty else { return out }
        let table = ProcessTable.snapshot()
        var resolved: [UInt64: AppIdentity] = [:]
        for c in missing {
            guard let pids = CoalitionReader.members(of: c.id, tasksHint: Int(c.tasks)), !pids.isEmpty else { continue }
            if pids.contains(0) {
                resolved[c.id] = .kernel
                continue
            }
            let candidates = pids.compactMap { pid -> (ProcessEntry, TopNBuilder.NameInfo)? in
                guard let entry = table[pid] else { return nil }
                let info = TopNBuilder.resolveName(path: ProcessInfoReader.path(of: pid), command: entry.command, pid: pid)
                return (entry, info)
            }
            let inApp = candidates.filter { $0.1.appPath != nil }
            guard let rep = (inApp.isEmpty ? candidates : inApp).min(by: { $0.0.startMicros < $1.0.startMicros }) else {
                continue
            }
            resolved[c.id] = identity(for: rep.1, command: rep.0.command)
        }
        state.withLock { s in
            if s.byCoalition.count + resolved.count > Self.cacheLimit { s.byCoalition.removeAll(keepingCapacity: true) }
            s.byCoalition.merge(resolved) { _, new in new }
        }
        return out.merging(resolved) { _, new in new }
    }

    private func identity(for info: TopNBuilder.NameInfo, command: String) -> AppIdentity {
        if let app = info.appPath {
            let bundleID: String? = state.withLock { s in
                if let cached = s.bundleIDs[app] { return cached }
                let id = Bundle(path: app)?.bundleIdentifier
                s.bundleIDs[app] = id
                return id
            }
            return AppIdentity(key: bundleID ?? app, name: info.name)
        }
        if let path = info.path { return AppIdentity(key: path, name: info.name) }
        return AppIdentity(key: "comm:" + (command.isEmpty ? info.name : command), name: info.name)
    }
}
