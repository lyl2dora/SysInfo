// assert_probe.swift — read-only: who prevents sleep (IOPMCopyAssertionsByProcess / IOPMCopyAssertionsStatus),
// plus low-power-mode / thermal / CPU power status. Creates no assertions.
import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin
import notify

func pname(_ pid: Int) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let r = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
    return r > 0 ? (String(cString: buf) as NSString).lastPathComponent : "?"
}

var status: Unmanaged<CFDictionary>?
let kr1 = IOPMCopyAssertionsStatus(&status)
print("IOPMCopyAssertionsStatus kr=\(kr1)")
if let s = status?.takeRetainedValue() as? [String: Int] {
    for (k, v) in s.sorted(by: { $0.key < $1.key }) { print("  \(k) = \(v)") }
}

var byProc: Unmanaged<CFDictionary>?
let kr2 = IOPMCopyAssertionsByProcess(&byProc)
print("IOPMCopyAssertionsByProcess kr=\(kr2)")
if let d = byProc?.takeRetainedValue() as NSDictionary? {
    print("  processes with assertions: \(d.count)")
    for (k, v) in d {
        let pid = (k as? NSNumber)?.intValue ?? -1
        let arr = v as? [[String: Any]] ?? []
        for a in arr {
            let type = a[kIOPMAssertionTypeKey] as? String ?? "?"
            let name = a[kIOPMAssertionNameKey] as? String ?? "?"
            let level = a[kIOPMAssertionLevelKey] as? Int ?? -1
            let proc = a["Process Name"] as? String ?? pname(pid)
            let created = a["AssertStartWhen"] ?? a["AssertionCreateTime"] ?? "?"
            print("  pid=\(pid) (\(proc)) type=\(type) level=\(level) name=\"\(name)\" start=\(created) keys=\(a.keys.sorted())")
        }
    }
}

// Private: IOPMCopyAssertionsByType, IOPMCopyActiveAsyncAssertionsByProcess, IOPMCopyAssertionActivityLog
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
for n in ["IOPMCopyAssertionsByType", "IOPMCopyActiveAsyncAssertionsByProcess", "IOPMCopyAssertionActivityLog", "IOPMCopyAssertionActivityUpdate", "IOPMCopyPowerStateInfo", "IOPMCopySystemPowerSettings", "IOPMCopyUserActivityLevelDescription", "IOPMGetLastWakeTime", "IOPMCopySleepWakeFailure", "IOPMGetUUID", "IOPMSetLowPowerMode", "IOPMCopyPowerHistory"] {
    print("dlsym(\(n)) = \(dlsym(iokit, n) != nil ? "present" : "absent")")
}
typealias ByTypeFn = @convention(c) (CFString, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> IOReturn
if let s = dlsym(iokit, "IOPMCopyAssertionsByType") {
    let f = unsafeBitCast(s, to: ByTypeFn.self)
    for t in ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion"] {
        var arr: Unmanaged<CFArray>?
        let kr = f(t as CFString, &arr)
        let a = arr?.takeRetainedValue() as? [[String: Any]] ?? []
        print("IOPMCopyAssertionsByType(\(t)) kr=\(kr) count=\(a.count) \(a.map { "\($0["Process Name"] ?? $0["AssertPID"] ?? "?"):\($0[kIOPMAssertionNameKey] ?? "?")" })")
    }
}

// Thermal / CPU power
var tl: UInt32 = 0
print("IOPMGetThermalWarningLevel kr=\(IOPMGetThermalWarningLevel(&tl)) level=\(tl)")
var cpu: Unmanaged<CFDictionary>?
let kr3 = IOPMCopyCPUPowerStatus(&cpu)
print("IOPMCopyCPUPowerStatus kr=\(String(format: "0x%x", kr3)) \(cpu?.takeRetainedValue() as NSDictionary? ?? [:])")

// Low power mode & thermal state
let pi = ProcessInfo.processInfo
print("ProcessInfo.isLowPowerModeEnabled = \(pi.isLowPowerModeEnabled)")
print("ProcessInfo.thermalState = \(pi.thermalState.rawValue) (0 nominal,1 fair,2 serious,3 critical)")
// notify(3) low-power state keys
for key in ["com.apple.system.lowpowermode", "com.apple.system.powermanagement.lowpowermode", "com.apple.system.thermalpressurelevel", "com.apple.system.powersources.source", "com.apple.system.powersources.percent", "com.apple.system.powersources.timeremaining"] {
    var tok: Int32 = 0
    if notify_register_check(key, &tok) == UInt32(NOTIFY_STATUS_OK) {
        var st: UInt64 = 0
        notify_get_state(tok, &st)
        print("notify_get_state(\(key)) = \(st)")
        notify_cancel(tok)
    }
}
