// notify_probe.swift — passive listener: which power-source change channels fire on this Mac (UPS + AirPods, no battery).
// Registers listeners only; changes nothing. Runs for N seconds (argv[1], default 150).
import Foundation
import IOKit
import IOKit.ps
import notify

let dur = Double(CommandLine.arguments.dropFirst().first ?? "150") ?? 150
let t0 = Date()
func ts() -> String { String(format: "+%6.1fs", Date().timeIntervalSince(t0)) }
var counts: [String: Int] = [:]
func hit(_ k: String, _ extra: String = "") { counts[k, default: 0] += 1; print("\(ts()) \(k) \(extra)"); fflush(stdout) }

func upsSummary() -> String {
    let b = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let l = IOPSCopyPowerSourcesList(b).takeRetainedValue() as [CFTypeRef]
    return l.compactMap { IOPSGetPowerSourceDescription(b, $0)?.takeUnretainedValue() as? [String: Any] }
        .map { "\($0[kIOPSTypeKey] ?? "?"):\($0[kIOPSCurrentCapacityKey] ?? "?")% tte=\($0[kIOPSTimeToEmptyKey] ?? "?") state=\($0[kIOPSPowerSourceStateKey] ?? "?")" }.joined(separator: "; ")
}

// 1. public run-loop sources
let s1 = IOPSNotificationCreateRunLoopSource({ _ in hit("IOPSNotificationCreateRunLoopSource", upsSummary()) }, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetMain(), s1, .defaultMode)
let s2 = IOPSCreateLimitedPowerNotification({ _ in hit("IOPSCreateLimitedPowerNotification") }, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetMain(), s2, .defaultMode)

// 2. private accessory run-loop source
typealias AccFn = @convention(c) (@convention(c) (UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Unmanaged<CFRunLoopSource>?
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
if let sym = dlsym(iokit, "IOPSAccNotificationCreateRunLoopSource") {
    let f = unsafeBitCast(sym, to: AccFn.self)
    if let s3 = f({ _ in hit("IOPSAccNotificationCreateRunLoopSource(private)") }, nil)?.takeRetainedValue() {
        CFRunLoopAddSource(CFRunLoopGetMain(), s3, .defaultMode); print("registered IOPSAccNotificationCreateRunLoopSource")
    } else { print("IOPSAccNotificationCreateRunLoopSource returned nil") }
}

// 3. notify(3) channels
let keys = ["com.apple.system.powersources", "com.apple.system.powersources.source", "com.apple.system.powersources.timeremaining",
            "com.apple.system.powersources.percent", "com.apple.system.powersources.lowbattery", "com.apple.system.powersources.criticallevel",
            "com.apple.system.powersources.attach", "com.apple.system.accpowersources.attach", "com.apple.system.accpowersources.source",
            "com.apple.system.accpowersources.timeremaining", "com.apple.system.accpowersources.percent",
            "com.apple.system.lowpowermode", "com.apple.system.powermanagement.lowpowermode", "com.apple.system.thermalpressurelevel",
            "com.apple.system.powermanagement.useractivity2", "com.apple.system.powermanagement.assertions",
            "com.apple.system.powermanagement.assertions.anychange", "com.apple.system.powermanagement.assertions.timeout",
            "com.apple.powermanagement.systempowerstate"]
var toks: [Int32] = []
for k in keys {
    var tok: Int32 = 0
    let r = notify_register_dispatch(k, &tok, DispatchQueue.main) { t in
        var st: UInt64 = 0; notify_get_state(t, &st); hit("notify:\(k)", "state=\(st)")
    }
    if r == 0 { toks.append(tok) } else { print("notify_register_dispatch(\(k)) failed \(r)") }
}

// 4. Foundation
NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
    hit("NSProcessInfoPowerStateDidChange", "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)") }
NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
    hit("thermalStateDidChange", "\(ProcessInfo.processInfo.thermalState.rawValue)") }

// 5. IOKit general-interest on AppleSmartBattery (the 60-s telemetry refresh on the battery-less mini)
let port = IONotificationPortCreate(kIOMainPortDefault)!
IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
let sb = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
var note: io_object_t = 0
let kr = IOServiceAddInterestNotification(port, sb, kIOGeneralInterest, { _, _, msgType, _ in
    let v = IORegistryEntryCreateCFProperty(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")), "UpdateTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    hit("AppleSmartBattery kIOGeneralInterest", String(format: "msg=0x%x UpdateTime=%@", msgType, "\(v ?? "nil" as Any)"))
}, nil, &note)
print("IOServiceAddInterestNotification(AppleSmartBattery) kr=\(kr)")
print("initial: \(upsSummary())")

DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
    print("=== done after \(dur)s; counts: \(counts.sorted { $0.key < $1.key })")
    exit(0)
}
CFRunLoopRun()
