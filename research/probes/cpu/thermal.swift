// Probe: thermal state / pressure: ProcessInfo.thermalState, notify(3) kOSThermalNotificationPressureLevelName
// ("com.apple.system.thermalpressurelevel"), IOPMCopyCPUPowerStatus / IOPMGetThermalWarningLevel (IOKit.pwr_mgt), load avg, uptime, host load info.
import Foundation
import IOKit.pwr_mgt
import Darwin
import notify

let pi = ProcessInfo.processInfo
let names = ["nominal", "fair", "serious", "critical"]
print("ProcessInfo.thermalState =", pi.thermalState.rawValue, names[pi.thermalState.rawValue])
print("ProcessInfo.isLowPowerModeEnabled =", pi.isLowPowerModeEnabled)
print("kOSThermalNotificationPressureLevelName =", String(cString: kOSThermalNotificationPressureLevelName))
var token: Int32 = 0
let r = notify_register_check(kOSThermalNotificationPressureLevelName, &token)
var state: UInt64 = 0
let g = notify_get_state(token, &state)
print("notify_register_check=\(r) notify_get_state=\(g) pressure level state=\(state) (0 nominal,1 moderate,2 heavy,3 trapping,4 sleeping)")
// IOPM thermal APIs
var level: UInt32 = 0
print("IOPMGetThermalWarningLevel ret=\(String(format: "0x%x", IOPMGetThermalWarningLevel(&level))) level=\(level) (kIOPMThermalWarningLevelNormal=\(kIOPMThermalLevelNormal))")
var cpuStatus: Unmanaged<CFDictionary>?
let cs = IOPMCopyCPUPowerStatus(&cpuStatus)
print("IOPMCopyCPUPowerStatus ret=\(String(format: "0x%x", cs)) dict=\(String(describing: cpuStatus?.takeRetainedValue()))")
// notification-based observation works (register for both)
var tok2: Int32 = 0
let rr = notify_register_dispatch(kOSThermalNotificationPressureLevelName, &tok2, DispatchQueue.main) { _ in print("pressure changed") }
print("notify_register_dispatch=\(rr) (dispatch-based change notification available)")
// Additional 'thermalpressurelevel' style keys
for key in ["com.apple.system.thermalpressurelevel", "com.apple.system.thermalpressurelevel.cold", "com.apple.system.powermanagement.cpupowerstatus"] {
    var t: Int32 = 0; var st: UInt64 = 0
    let a = notify_register_check(key, &t); let b = notify_get_state(t, &st)
    print("notify \(key): reg=\(a) get=\(b) state=\(st)")
}
// Load average / uptime natively (Stats spawns /usr/bin/uptime)
var la = [Double](repeating: 0, count: 3)
print("getloadavg ->", getloadavg(&la, 3), la.map { String(format: "%.2f", $0) })
var hl = host_load_info(); var c = mach_msg_type_number_t(MemoryLayout<host_load_info>.stride / MemoryLayout<integer_t>.stride)
let kr = withUnsafeMutablePointer(to: &hl) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics(mach_host_self(), HOST_LOAD_INFO, $0, &c) } }
print("host_statistics(HOST_LOAD_INFO) kr=\(kr) avenrun=\([hl.avenrun.0, hl.avenrun.1, hl.avenrun.2].map { String(format: "%.2f", Double($0) / Double(LOAD_SCALE)) }) mach_factor=\([hl.mach_factor.0, hl.mach_factor.1, hl.mach_factor.2].map { String(format: "%.2f", Double($0) / Double(LOAD_SCALE)) })")
var bt = timeval(); var sz = MemoryLayout<timeval>.size; var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
sysctl(&mib, 2, &bt, &sz, nil, 0)
let boot = Date(timeIntervalSince1970: Double(bt.tv_sec) + Double(bt.tv_usec) / 1e6)
print("kern.boottime =", boot, " uptime(wall) =", String(format: "%.0fs", Date().timeIntervalSince(boot)))
print("ProcessInfo.systemUptime (excludes sleep) =", String(format: "%.0fs", pi.systemUptime))
print("clock_gettime_nsec_np(CLOCK_MONOTONIC) (incl. sleep) =", String(format: "%.0fs", Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9))
print("processorCount/activeProcessorCount =", pi.processorCount, pi.activeProcessorCount)
