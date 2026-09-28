// 降频信号的 app 层汇总（M0 设计 §5.3，K20、D19、D25）。
//
// 信号：
// - 低电量模式：`ProcessInfo.isLowPowerModeEnabled`，监听 `NSProcessInfoPowerStateDidChange`；
// - 过热：`thermalState` 达到 `.serious` 及以上；
// - UPS 或电池放电：`IOPSNotificationCreateRunLoopSource` + `IOPSGetProvidingPowerSourceType`，去抖 5 s；
// - 锁屏：分布式通知 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`；
// - 显示器睡眠：`NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`；
// - 诊断页的手动开关（测试用）。
// 汇总规则见 `ThrottlePolicy`；结果交给引擎的 `setThrottle(factor:reasons:)`。每次信号变化都写日志。
//
// 另外：系统唤醒时回调 `onWake`，由 app 让引擎重新自检（K19）。
//
// 通知只报告变化，所以 start() 时主动读一次各信号的当前值，包括锁屏和显示器睡眠（见 SessionState）：
// 在锁屏或显示器已睡眠时启动，也能立即暂停。

import AppKit
import IOKit.ps
import Observation
import SysCollectors
import OSLog

@Observable
final class ThrottleMonitor {
    /// UPS/电池状态变化后，稳定这么久才生效（K20：电源切换去抖）。
    static let powerSourceDebounce: Duration = .seconds(5)

    /// 当前各信号的取值。
    private(set) var signals = ThrottleSignals()
    /// 最近一次交给引擎的结果。
    private(set) var applied: (factor: ThrottleFactor, reasons: Set<ThrottleReason>) = (.normal, [])

    /// 设置里的「自动降频」开关。
    var automatic: Bool {
        didSet {
            guard automatic != oldValue else { return }
            Log.throttle.info("自动降频开关：\(self.automatic ? "开" : "关", privacy: .public)")
            apply()
        }
    }

    /// 诊断页的手动降频开关（K20，测试用）。
    var manual: Bool {
        get { signals.manual }
        set {
            guard newValue != signals.manual else { return }
            update(\.manual, to: newValue, source: "手动开关")
        }
    }

    /// 系统唤醒后调用（K19：唤醒时复检）。
    @ObservationIgnored var onWake: (() -> Void)?

    @ObservationIgnored private let engine: SamplingEngine
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    @ObservationIgnored private var powerSourceRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var powerSourceDebounceTask: Task<Void, Never>?
    /// 串行地把结果交给引擎，保证先后顺序。
    @ObservationIgnored private var engineUpdate: Task<Void, Never>?

    init(engine: SamplingEngine, automatic: Bool) {
        self.engine = engine
        self.automatic = automatic
    }

    func start() {
        let processInfo = ProcessInfo.processInfo
        signals.lowPowerMode = processInfo.isLowPowerModeEnabled
        signals.thermalPressure = Self.isUnderThermalPressure(processInfo.thermalState)
        signals.onBatteryPower = Self.isOnBatteryPower() ?? false
        if let locked = SessionState.isScreenLocked() {
            signals.screenLocked = locked
        } else {
            Log.throttle.notice("读不到当前会话的锁屏状态（没有 GUI 会话字典），按未锁屏处理")
        }
        if let asleep = SessionState.areDisplaysAsleep() {
            signals.displayAsleep = asleep
        } else {
            Log.throttle.notice("读不到显示器睡眠状态（没有在线显示器），按未睡眠处理")
        }

        let main = NotificationCenter.default
        observe(main, .NSProcessInfoPowerStateDidChange) { monitor in
            monitor.update(\.lowPowerMode, to: ProcessInfo.processInfo.isLowPowerModeEnabled, source: "低电量模式通知")
        }
        observe(main, ProcessInfo.thermalStateDidChangeNotification) { monitor in
            let state = ProcessInfo.processInfo.thermalState
            monitor.update(
                \.thermalPressure, to: Self.isUnderThermalPressure(state),
                source: "thermalState=\(Self.describe(state))")
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { monitor in
            monitor.update(\.displayAsleep, to: true, source: "显示器睡眠")
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { monitor in
            monitor.update(\.displayAsleep, to: false, source: "显示器唤醒")
        }
        observe(workspace, NSWorkspace.didWakeNotification) { monitor in
            Log.throttle.info("系统唤醒")
            monitor.onWake?()
        }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { monitor in
            monitor.update(\.screenLocked, to: true, source: "锁屏")
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { monitor in
            monitor.update(\.screenLocked, to: false, source: "解锁")
        }

        installPowerSourceNotification()

        Log.throttle.info("降频信号初始值：\(Self.describe(self.signals), privacy: .public)")
        apply()
    }

    // MARK: - 信号

    private func update(_ keyPath: WritableKeyPath<ThrottleSignals, Bool>, to value: Bool, source: String) {
        let old = signals[keyPath: keyPath]
        signals[keyPath: keyPath] = value
        Log.throttle.info(
            "信号变化（\(source, privacy: .public)）：\(old ? "是" : "否", privacy: .public) → \(value ? "是" : "否", privacy: .public)；当前 \(Self.describe(self.signals), privacy: .public)"
        )
        apply()
    }

    private func apply() {
        let result = ThrottlePolicy.evaluate(signals, automatic: automatic)
        guard result.factor != applied.factor || result.reasons != applied.reasons else { return }
        applied = result
        Log.throttle.info(
            "降频：\(String(describing: result.factor), privacy: .public)，原因 \(result.reasons.sorted().map(\.rawValue), privacy: .public)"
        )
        let previous = engineUpdate
        engineUpdate = Task { [engine] in
            await previous?.value
            await engine.setThrottle(factor: result.factor, reasons: result.reasons)
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        handler: @escaping @MainActor (ThrottleMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    // MARK: - UPS / 电池

    private func installPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let source = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<ThrottleMonitor>.fromOpaque(context).takeUnretainedValue().powerSourcesChanged()
                    }
                }, context)?.takeRetainedValue()
        else {
            Log.throttle.error("IOPSNotificationCreateRunLoopSource 失败，UPS/电池放电信号不可用")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    /// 电源变化通知（主线程 run loop）。去抖：状态稳定 5 s 后才生效。
    private func powerSourcesChanged() {
        let onBattery = Self.isOnBatteryPower() ?? false
        powerSourceDebounceTask?.cancel()
        guard onBattery != signals.onBatteryPower else {
            powerSourceDebounceTask = nil
            return
        }
        Log.throttle.info("电源变化：\(onBattery ? "UPS/电池供电" : "外接电源", privacy: .public)，\(Self.powerSourceDebounce) 后确认")
        powerSourceDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.powerSourceDebounce)
            guard !Task.isCancelled, let self else { return }
            let confirmed = Self.isOnBatteryPower() ?? false
            guard confirmed == onBattery, confirmed != self.signals.onBatteryPower else { return }
            self.update(\.onBatteryPower, to: confirmed, source: "电源（已去抖）")
        }
    }

    /// 当前是否由 UPS 或电池供电；读不到时为 nil。
    private static func isOnBatteryPower() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return nil }
        let value = type as String
        return value == kIOPMBatteryPowerKey || value == kIOPMUPSPowerKey
    }

    // MARK: - 描述

    private static func isUnderThermalPressure(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }

    private static func describe(_ signals: ThrottleSignals) -> String {
        let processInfo = ProcessInfo.processInfo
        return
            "lowPower=\(signals.lowPowerMode) thermal=\(describe(processInfo.thermalState)) onBattery=\(signals.onBatteryPower) locked=\(signals.screenLocked) displayAsleep=\(signals.displayAsleep) manual=\(signals.manual)"
    }
}
