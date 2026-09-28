// ps_probe.swift — read-only dump of IOPowerSources (public + private), AppleSmartBattery presence,
// external adapter details, warning level, time remaining.
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

func j(_ o: Any?) -> String {
    guard let o = o else { return "nil" }
    if JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
        return String(data: d, encoding: .utf8)!
    }
    return "\(o)"
}

print("=== date \(Date())")
// 1. public IOPS snapshot
let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
print("IOPSCopyPowerSourcesList count=\(list.count)")
for (i, ps) in list.enumerated() {
    let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
    print("-- public ps[\(i)] --\n\(j(d))")
}
print("IOPSGetProvidingPowerSourceType = \(IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? ?? "nil")")
let tr = IOPSGetTimeRemainingEstimate()
print("IOPSGetTimeRemainingEstimate = \(tr) (unlimited=\(kIOPSTimeRemainingUnlimited), unknown=\(kIOPSTimeRemainingUnknown))")
print("IOPSGetBatteryWarningLevel = \(IOPSGetBatteryWarningLevel().rawValue)")
if let ad = IOPSCopyExternalPowerAdapterDetails() {
    print("IOPSCopyExternalPowerAdapterDetails = \(j(ad.takeRetainedValue() as? [String: Any]))")
} else {
    print("IOPSCopyExternalPowerAdapterDetails = nil")
}

// 2. private IOPS API via dlsym
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
typealias ByTypeFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
typealias ArrFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
typealias GetFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
typealias BoolFn = @convention(c) () -> Bool
for name in ["IOPSCopyPowerSourcesByType", "IOPSCopyInternalBatteriesArray", "IOPSCopyUPSArray", "IOPSGetActiveBattery", "IOPSGetActiveUPS", "IOPSDrawingUnlimitedPower", "IOPSAccNotificationCreateRunLoopSource", "IOPSCopyPowerSourcesByTypePrecise", "IOPSCopyChargeLog", "IOPSGetSupportedPowerSources", "IOPSCopyUPSShutdownLevels", "IOPMCopyBatteryHeatMap", "IOPSGetPercentRemaining", "IOPSIsBatteryAvailable", "IOPSCopyAdapterDetails"] {
    print("dlsym(\(name)) = \(dlsym(iokit, name) != nil ? "present" : "absent")")
}
if let s = dlsym(iokit, "IOPSCopyPowerSourcesByType") {
    let f = unsafeBitCast(s, to: ByTypeFn.self)
    for t: Int32 in 0...6 {
        guard let b = f(t)?.takeRetainedValue() else { print("ByType(\(t)) = nil"); continue }
        let l = IOPSCopyPowerSourcesList(b).takeRetainedValue() as [CFTypeRef]
        let names = l.compactMap { (IOPSGetPowerSourceDescription(b, $0)?.takeUnretainedValue() as? [String: Any]).map { "\($0[kIOPSNameKey] ?? "?")|\($0[kIOPSTypeKey] ?? "?")|\($0[kIOPSCurrentCapacityKey] ?? "?")%" } }
        print("IOPSCopyPowerSourcesByType(\(t)) count=\(l.count) \(names)")
        if t == 0 || t == 4 {
            for ps in l { print("  full: \(j(IOPSGetPowerSourceDescription(b, ps)?.takeUnretainedValue() as? [String: Any]))") }
        }
    }
}
if let s = dlsym(iokit, "IOPSCopyUPSArray") {
    let f = unsafeBitCast(s, to: ArrFn.self)
    let a = f(blob)?.takeRetainedValue() as? [CFTypeRef]
    print("IOPSCopyUPSArray count=\(a?.count ?? -1)")
}
if let s = dlsym(iokit, "IOPSCopyInternalBatteriesArray") {
    let f = unsafeBitCast(s, to: ArrFn.self)
    let a = f(blob)?.takeRetainedValue() as? [CFTypeRef]
    print("IOPSCopyInternalBatteriesArray count=\(a.map { "\($0.count)" } ?? "nil")")
}
if let s = dlsym(iokit, "IOPSGetActiveUPS") {
    let f = unsafeBitCast(s, to: GetFn.self)
    if let u = f(blob)?.takeUnretainedValue() {
        let d = IOPSGetPowerSourceDescription(blob, u)?.takeUnretainedValue() as? [String: Any]
        print("IOPSGetActiveUPS -> \(d?[kIOPSNameKey] ?? "?")")
    } else { print("IOPSGetActiveUPS -> nil") }
}
if let s = dlsym(iokit, "IOPSGetActiveBattery") {
    let f = unsafeBitCast(s, to: GetFn.self)
    print("IOPSGetActiveBattery -> \(f(blob) == nil ? "nil" : "non-nil")")
}
if let s = dlsym(iokit, "IOPSDrawingUnlimitedPower") {
    print("IOPSDrawingUnlimitedPower -> \(unsafeBitCast(s, to: BoolFn.self)())")
}

// 3. IORegistry: AppleSmartBattery & friends
for cls in ["AppleSmartBattery", "AppleSmartBatteryManager", "IOPMPowerSource", "AppleSmartBatteryManagerARM", "IOPMrootDomain", "AppleUSBHIDUPS", "IOHIDUPS", "IOUPSPlugIn"] {
    var it: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it)
    var n = 0
    var names: [String] = []
    while case let o = IOIteratorNext(it), o != 0 {
        n += 1
        var nm = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(o, &nm)
        names.append(String(cString: nm))
        IOObjectRelease(o)
    }
    IOObjectRelease(it)
    print("IOServiceMatching(\(cls)) kr=\(kr) count=\(n) \(names)")
}
let sb = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
print("Stats-style IOServiceGetMatchingService(AppleSmartBattery) = \(sb) (0 means absent; Stats then calls IORegistryEntryCreateCFProperty on 0)")
for key in ["CycleCount", "DesignCapacity", "AppleRawMaxCapacity", "AppleRawCurrentCapacity", "Temperature", "Voltage", "Amperage", "IsCharging", "BatteryData", "ChargerData", "AdapterDetails"] {
    let v = IORegistryEntryCreateCFProperty(sb, key as CFString, kCFAllocatorDefault, 0)
    print("  IORegistryEntryCreateCFProperty(\(sb), \(key)) = \(v == nil ? "nil" : "\(v!.takeRetainedValue())")")
}

// 4. IOPMrootDomain properties of interest
let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
for key in ["Supported Features", "IOPMSystemSleepType", "SleepWakeUUID", "System Boot Complete", "Wake Reason", "IOPMUserIsActive", "UserActivity", "AppleClamshellState", "IOPMCPUPowerStatus", "SystemPowerProfileOverrideDict", "IOSleepSupported", "Sleep Disabled", "DesktopMode"] {
    if let v = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0) {
        print("IOPMrootDomain[\(key)] = \(v.takeRetainedValue())")
    } else { print("IOPMrootDomain[\(key)] = nil") }
}
IOObjectRelease(root)
