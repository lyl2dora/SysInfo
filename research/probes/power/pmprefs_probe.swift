// pmprefs_probe.swift — read-only: energy mode (powermode / lowpowermode / highpowermode) and active PM preferences
// via private IOPMCopyActivePMPreferences / IOPMCopyPMPreferences (no writes).
import Foundation
import IOKit
import IOKit.pwr_mgt

let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
typealias CopyFn = @convention(c) () -> Unmanaged<CFDictionary>?
for n in ["IOPMCopyActivePMPreferences", "IOPMCopyPMPreferences", "IOPMCopySystemPowerSettings", "IOPMFeatureIsAvailable", "IOPMCopyUserActivityLevelDescription"] {
    print("dlsym(\(n)) = \(dlsym(iokit, n) != nil ? "present" : "absent")")
}
func show(_ fn: String) {
    guard let s = dlsym(iokit, fn) else { return }
    let d = unsafeBitCast(s, to: CopyFn.self)()?.takeRetainedValue() as? [String: Any]
    print("== \(fn):")
    for (k, v) in (d ?? [:]).sorted(by: { $0.key < $1.key }) {
        if let sub = v as? [String: Any] {
            let interesting = sub.filter { ["LowPowerMode", "HighPowerMode", "PowerMode", "powermode", "System Sleep Timer", "Display Sleep Timer"].contains($0.key) || $0.key.lowercased().contains("power") }
            print("  [\(k)] \(interesting.sorted { $0.key < $1.key })")
        } else { print("  \(k) = \(v)") }
    }
}
show("IOPMCopyActivePMPreferences")
show("IOPMCopySystemPowerSettings")
typealias FeatFn = @convention(c) (CFString, CFString?) -> Bool
if let s = dlsym(iokit, "IOPMFeatureIsAvailable") {
    let f = unsafeBitCast(s, to: FeatFn.self)
    for feat in ["LowPowerMode", "HighPowerMode", "PowerMode", "ProModeControl", "Automatic Restart On Power Loss", "Wake On LAN"] {
        print("IOPMFeatureIsAvailable(\(feat), AC) = \(f(feat as CFString, "AC Power" as CFString))")
    }
}
print("ProcessInfo.isLowPowerModeEnabled = \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
