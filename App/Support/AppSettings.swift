// 用户设置（M0 设计 §6）：@Observable，底层是 UserDefaults.standard。
// Debug（zone.lyl.sysinfo.dev）与 Release（zone.lyl.sysinfo）的 Bundle ID 不同，存储天然隔离（D16）。
//
// 键名（也可以用 `defaults write zone.lyl.sysinfo.dev <键> …` 修改，重启 app 后生效）：
// - general.interval      全局默认采集间隔，秒：1 / 2 / 5
// - general.autoThrottle  是否自动降频（K20、D25：默认开）
// - cpu.interval          CPU 模块的间隔覆盖：0 表示跟随全局，否则 1 / 2 / 5
// - menubar.cpu.visible   CPU item 是否显示

import Foundation
import Observation

/// 采集间隔，取基础 tick（1 s）的整数倍（D19、D25）。
enum SamplingInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    var id: Int { rawValue }
}

@Observable
final class AppSettings {
    enum Key {
        static let globalInterval = "general.interval"
        static let autoThrottle = "general.autoThrottle"
        static let cpuInterval = "cpu.interval"
        static let cpuItemVisible = "menubar.cpu.visible"
        static let historyCPU = "history.cpu.enabled"
        static let historyApps = "history.apps.enabled"
    }

    /// nil：不读写持久化存储，只用出厂默认值（`--factory-defaults`）。
    @ObservationIgnored private let defaults: UserDefaults?
    /// 任何一项设置被修改后调用（在 MainActor 上同步调用）。
    @ObservationIgnored var onChange: (() -> Void)?

    /// 全局默认采集间隔（D25）。
    var globalInterval: SamplingInterval {
        didSet { persist(globalInterval.rawValue, Key.globalInterval) }
    }

    /// CPU 模块的间隔覆盖；nil 表示跟随全局默认（D25）。
    var cpuIntervalOverride: SamplingInterval? {
        didSet { persist(cpuIntervalOverride?.rawValue ?? 0, Key.cpuInterval) }
    }

    /// CPU item 是否显示（K32：可见性以 app 设置为准）。
    var cpuItemVisible: Bool {
        didSet { persist(cpuItemVisible, Key.cpuItemVisible) }
    }

    /// 是否自动降频（K20、D25：默认开，可以关闭）。
    var autoThrottle: Bool {
        didSet { persist(autoThrottle, Key.autoThrottle) }
    }

    /// 是否记录 CPU 历史（D30：默认开）。
    var historyCPUEnabled: Bool {
        didSet { persist(historyCPUEnabled, Key.historyCPU) }
    }

    /// 是否记录每应用 CPU（D30：默认开）。
    var historyAppsEnabled: Bool {
        didSet { persist(historyAppsEnabled, Key.historyApps) }
    }

    /// CPU 模块实际使用的间隔。
    var cpuInterval: SamplingInterval { cpuIntervalOverride ?? globalInterval }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        globalInterval = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.globalInterval)) } ?? .oneSecond
        cpuIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.cpuInterval)) }
        cpuItemVisible = defaults?.object(forKey: Key.cpuItemVisible) as? Bool ?? true
        autoThrottle = defaults?.object(forKey: Key.autoThrottle) as? Bool ?? true
        historyCPUEnabled = defaults?.object(forKey: Key.historyCPU) as? Bool ?? true
        historyAppsEnabled = defaults?.object(forKey: Key.historyApps) as? Bool ?? true
    }

    private func persist(_ value: Any, _ key: String) {
        defaults?.set(value, forKey: key)
        onChange?()
    }
}
