// 电源断言（谁在阻止睡眠）采集器 `app.assertions`（D69，应用活动设计 §1.1、§3.1）。
//
// - 读：公开的 `IOPMCopyAssertionsByProcess`（约 0.3 ms，走 powerd 的 XPC）。按 `AssertionTrueType` 归类；
//   同一进程、类型、名字的多条合并计数（实测某远程桌面软件一个进程挂 12–28 条 `UserIsActive`）；
//   带 `AssertionOnBehalfOfPID` 的算到被代理的进程上（实测 coreaudiod 代某远程桌面软件持有）；pid → coalition；
// - 事件驱动：用私有的 `IOPMAssertionNotify` 向 powerd 登记 `…assertions.anychange`（不登记时 powerd 不发），
//   `notify_register_dispatch` 在本采集器的串行队列上回调；100 ms 内的多次通知合并成一次读取，结果交给订阅方；
// - 自检：读取可用（必需）；登记后自建并释放一个 `PreventUserIdleDisplaySleep` 断言（几毫秒），1 s 内收到通知才算
//   事件驱动可用（提示级）。不可用时订阅方改为每 60 s 登记需求轮询（`sample()` 同样会交付快照）；
// - 自检用的断言名固定为「SysInfo self-test」，读取时滤掉本进程的这条，不会进历史。

import Darwin
import Foundation
import IOKit.pwr_mgt
internal import CSysPrivate
import Synchronization
import SysModel
import notify

public final class PowerAssertionCollector: Collector {
    public static let collectorID: CollectorID = "app.assertions"
    public static let dataPath = "IOPMCopyAssertionsByProcess"
    /// powerd 在任意断言出现、消失时发的通知（需先登记）。
    static let notifyName = "com.apple.system.powermanagement.assertions.anychange"
    static let selfTestAssertionName = "SysInfo self-test"
    /// 通知合并窗口。
    static let debounce: DispatchTimeInterval = .milliseconds(100)

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var latest: PowerAssertionSnapshot?
        var readable: Bool?
        /// 事件驱动可用（登记成功且自检收到了通知）。
        var eventDriven = false
        var notifyToken: Int32?
        var pendingRead = false
        /// 自检等待通知中。
        var selfTestWaiting = false
        var handler: (@Sendable (PowerAssertionSnapshot) -> Void)?
        var lastDetail = ""
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "zone.lyl.sysinfo.assertions", qos: .utility)
    private let selfTestSignal = DispatchSemaphore(value: 0)

    public init() {}

    /// 最近一次读到的断言。
    public var latestSnapshot: PowerAssertionSnapshot? { state.withLock { $0.latest } }

    /// 事件驱动是否可用；不可用时由订阅方轮询（D69）。
    public var isEventDriven: Bool { state.withLock { $0.eventDriven } }

    /// 订阅断言变化：事件驱动时每次变化交付一次，轮询时每次 `sample()` 交付一次。在本采集器的队列或引擎队列上回调。
    public func setChangeHandler(_ handler: (@Sendable (PowerAssertionSnapshot) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let snapshot = Self.read()
        checks.append(
            SelfTestCheck(
                name: "app.assertions.read", passed: snapshot != nil,
                detail: snapshot.map { "\($0.assertions.count) merged assertions" } ?? "IOPMCopyAssertionsByProcess failed"))
        if let snapshot { state.withLock { $0.latest = snapshot } }
        let notify = notifyCheck()
        checks.append(SelfTestCheck(name: "app.assertions.notify", passed: notify.passed, detail: notify.detail, severity: .advisory))
        state.withLock {
            $0.readable = snapshot != nil
            $0.eventDriven = notify.passed
            $0.lastDetail = notify.detail
        }
        return SelfTestResult(checks: checks, dataPath: Self.dataPath + (notify.passed ? " + anychange notify" : " (polling)"))
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        guard state.withLock({ $0.readable }) != false, let snapshot = Self.read(now: time.wallClock) else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        let (handler, eventDriven) = state.withLock { s in
            s.latest = snapshot
            return (s.handler, s.eventDriven)
        }
        handler?(snapshot)
        return CollectorOutput(samples: [], status: eventDriven ? .ok : .degraded, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    // MARK: - 事件驱动

    /// 登记通知并用一次自建断言验证（几毫秒的 `PreventUserIdleDisplaySleep`）。
    private func notifyCheck() -> (passed: Bool, detail: String) {
        guard csp_pm_available() != 0 else { return (false, "IOPMAssertionNotify not resolved") }
        let rc = csp_pm_assertion_notify_register(Self.notifyName)
        guard rc == 0 else { return (false, "IOPMAssertionNotify returned 0x\(String(UInt32(bitPattern: rc), radix: 16))") }
        guard installNotifyHandler() else { return (false, "notify_register_dispatch failed") }
        // 清掉之前残留的信号，再自建断言等通知。
        while selfTestSignal.wait(timeout: .now()) == .success {}
        state.withLock { $0.selfTestWaiting = true }
        var assertion: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.selfTestAssertionName as CFString, &assertion)
        guard created == kIOReturnSuccess else {
            state.withLock { $0.selfTestWaiting = false }
            return (false, "self-test assertion create failed 0x\(String(UInt32(bitPattern: created), radix: 16))")
        }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let received = selfTestSignal.wait(timeout: .now() + 1) == .success
        let latency = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        IOPMAssertionRelease(assertion)
        state.withLock { $0.selfTestWaiting = false }
        return received
            ? (true, String(format: "anychange after %.1f ms", latency))
            : (false, "no anychange within 1 s after registering")
    }

    /// 只装一次；返回是否已装好。
    private func installNotifyHandler() -> Bool {
        if state.withLock({ $0.notifyToken }) != nil { return true }
        var token: Int32 = 0
        let status = notify_register_dispatch(Self.notifyName, &token, queue) { [weak self] _ in
            self?.notified()
        }
        guard status == NOTIFY_STATUS_OK else { return false }
        state.withLock { $0.notifyToken = token }
        return true
    }

    private func notified() {
        let schedule = state.withLock { s -> Bool in
            if s.selfTestWaiting {
                s.selfTestWaiting = false
                selfTestSignal.signal()
            }
            guard !s.pendingRead else { return false }
            s.pendingRead = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            guard let self else { return }
            let snapshot = Self.read()
            let handler = self.state.withLock { s -> (@Sendable (PowerAssertionSnapshot) -> Void)? in
                s.pendingRead = false
                if let snapshot { s.latest = snapshot }
                return s.eventDriven ? s.handler : nil
            }
            if let snapshot { handler?(snapshot) }
        }
    }

    deinit {
        if let token = state.withLock({ $0.notifyToken }) { notify_cancel(token) }
    }

    // MARK: - 读取

    /// 原始的一条断言（解析 `IOPMCopyAssertionsByProcess` 的结果后、合并前）。
    struct RawAssertion: Hashable, Sendable {
        var pid: Int32
        var onBehalfOf: Int32?
        var processName: String
        var type: String
        var name: String
        var start: Date?
    }

    /// 读当前全部断言并合并；接口失败时为 nil。
    public static func read(now: Date = Date()) -> PowerAssertionSnapshot? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let dictionary = unmanaged?.takeRetainedValue()
        else { return nil }
        let raw = parse(dictionary as NSDictionary)
        var merged = merge(raw, ownPID: getpid())
        for index in merged.indices {
            merged[index].coalitionID = CoalitionReader.coalition(ofPID: merged[index].pid)
        }
        return PowerAssertionSnapshot(time: now, assertions: merged)
    }

    static func parse(_ dictionary: NSDictionary) -> [RawAssertion] {
        var out: [RawAssertion] = []
        for (key, value) in dictionary {
            guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [NSDictionary] else { continue }
            for item in list {
                let type = (item["AssertionTrueType"] as? String) ?? (item["AssertType"] as? String) ?? "?"
                let behalf = (item["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                out.append(
                    RawAssertion(
                        pid: pid, onBehalfOf: behalf.flatMap { $0 > 0 && $0 != pid ? $0 : nil },
                        processName: (item["Process Name"] as? String) ?? "pid \(pid)", type: type,
                        name: (item["AssertName"] as? String) ?? "", start: item["AssertStartWhen"] as? Date))
            }
        }
        return out
    }

    /// 合并：按「归属 pid + 类型 + 名字」合并计数，开始时刻取最早；滤掉本进程的自检断言。按归属 pid、类型、名字排序。
    static func merge(_ raw: [RawAssertion], ownPID: Int32) -> [PowerAssertion] {
        var merged: [String: PowerAssertion] = [:]
        for item in raw {
            if item.pid == ownPID, item.name == selfTestAssertionName { continue }
            let assertion = PowerAssertion(
                pid: item.onBehalfOf ?? item.pid, holderPID: item.pid, holderName: item.processName, type: item.type,
                name: item.name, count: 1, since: item.start)
            if var existing = merged[assertion.spanKey] {
                existing.count += 1
                if let start = item.start { existing.since = min(existing.since ?? start, start) }
                merged[assertion.spanKey] = existing
            } else {
                merged[assertion.spanKey] = assertion
            }
        }
        return merged.values.sorted { ($0.pid, $0.type, $0.name) < ($1.pid, $1.type, $1.name) }
    }
}
