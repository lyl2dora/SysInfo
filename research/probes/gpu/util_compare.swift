// Probe: side-by-side GPU utilization estimators, 1s cadence:
//   (a) IOAccelerator PerformanceStatistics "Device/Renderer/Tiler Utilization %" (Stats' method)
//   (b) IOReport GPU Stats/GPU Performance States (GPUPH) non-OFF residency + avg active freq
//   (c) sum over all AGXDeviceUserClient AppUsage.accumulatedGPUTime deltas (per-process accounting)
//   (d) IOReport Energy Model "GPU Energy" (AGX, nJ) -> W
// usage: util_compare <count>
// build: xcrun swiftc -O -import-objc-header ioreport_bridge.h -o util_compare util_compare.swift -lIOReport -framework IOKit
import Foundation
import IOKit

func str(_ s: Unmanaged<CFString>?) -> String { (s?.takeUnretainedValue() as String?) ?? "" }
func accel() -> (io_registry_entry_t, [String: Any])? {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    guard s != 0 else { return nil }
    var p: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0)
    return (s, p!.takeRetainedValue() as! [String: Any])
}
func totalGPUTimeNs(_ acc: io_registry_entry_t) -> UInt64 {
    var kids = io_iterator_t(); var sum: UInt64 = 0
    IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids)
    while case let c = IOIteratorNext(kids), c != 0 {
        if let arr = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
            for a in arr { sum += (a["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
        }
        IOObjectRelease(c)
    }
    IOObjectRelease(kids)
    return sum
}
func freqTable() -> [Double] {
    var it = io_iterator_t(); IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it)
    defer { IOObjectRelease(it) }
    while case let e = IOIteratorNext(it), e != 0 {
        defer { IOObjectRelease(e) }
        var nm = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(e, &nm)
        if String(cString: nm) == "pmgr", let d = IORegistryEntryCreateCFProperty(e, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
            return d.withUnsafeBytes { r in (0..<(r.count / 8)).map { Double(r.load(fromByteOffset: $0 * 8, as: UInt32.self)) / 1e6 } }
        }
    }
    return []
}
let table = freqTable()
let parts = [IOReportCopyChannelsInGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)!.takeRetainedValue(),
             IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)!.takeRetainedValue()]
let merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, parts[0])!
IOReportMergeChannels(merged, parts[1], nil)
var subbed: Unmanaged<CFMutableDictionary>?
let sub = IOReportCreateSubscription(nil, merged, &subbed, 0, nil)!
let sc = subbed!.takeRetainedValue()

let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 10
var prev = IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue()
var (accS, _) = accel()!
var prevGT = totalGPUTimeNs(accS); IOObjectRelease(accS)
var prevT = Date()
print("t\tdevUtil%\trenUtil%\ttilUtil%\tGPUPH_active%\tavgMHz\tsumProcGPU%\tGPU_W")
for i in 0..<count {
    Thread.sleep(forTimeInterval: 1)
    let cur = IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue()
    let (acc, props) = accel()!
    let gt = totalGPUTimeNs(acc); IOObjectRelease(acc)
    let now = Date(); let dt = now.timeIntervalSince(prevT)
    let d = IOReportCreateSamplesDelta(prev, cur, nil)!.takeRetainedValue() as NSDictionary
    var active = 0.0, total = 0.0, fsum = 0.0, gpuJ = 0.0
    for c in d["IOReportChannels"] as! [CFDictionary] {
        let g = str(IOReportChannelGetGroup(c)), n = str(IOReportChannelGetChannelName(c))
        if g == "GPU Stats" {
            for k in 0..<IOReportStateGetCount(c) {
                let r = Double(IOReportStateGetResidency(c, k)); total += r
                if str(IOReportStateGetNameForIndex(c, k)) != "OFF" { active += r; fsum += r * (Int(k) < table.count ? table[Int(k)] : 0) }
            }
        } else if n == "GPU Energy" { gpuJ = Double(IOReportSimpleGetIntegerValue(c, 0)) / 1e9 }
    }
    let ps = props["PerformanceStatistics"] as! [String: Any]
    let f = { (k: String) in (ps[k] as? NSNumber)?.intValue ?? -1 }
    print(String(format: "%d\t%d\t%d\t%d\t%.1f\t%.0f\t%.1f\t%.2f", i, f("Device Utilization %"), f("Renderer Utilization %"), f("Tiler Utilization %"),
                 total > 0 ? 100 * active / total : 0, active > 0 ? fsum / active : 0, Double(gt &- prevGT) / (dt * 1e9) * 100, gpuJ / dt))
    prev = cur; prevGT = gt; prevT = now
}
