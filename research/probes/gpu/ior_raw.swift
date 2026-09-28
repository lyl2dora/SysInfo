// Probe: raw (absolute, non-delta) IOReport values for selected groups, two samples 1s apart,
// plus a direct IOReportCopyChannelsInGroup vs IOReportCopyAllChannels comparison.
// usage: ior_raw <group> [subgroup] [nameFilter]
// build: xcrun swiftc -O -import-objc-header ioreport_bridge.h -o ior_raw ior_raw.swift -lIOReport
import Foundation

let a = CommandLine.arguments
let group = a.count > 1 ? a[1] : "Energy Model"
let subgroup: String? = a.count > 2 && a[2] != "-" ? a[2] : nil
let filter: String? = a.count > 3 ? a[3] : nil
func str(_ s: Unmanaged<CFString>?) -> String { (s?.takeUnretainedValue() as String?) ?? "" }

guard let ch = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() else { print("no channels"); exit(1) }
let m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch)!
var subbed: Unmanaged<CFMutableDictionary>?
guard let sub = IOReportCreateSubscription(nil, m, &subbed, 0, nil) else { print("IOReportCreateSubscription returned NULL"); exit(1) }
let sc = subbed!.takeRetainedValue()
print("subscribed channels: \(((sc as NSDictionary)["IOReportChannels"] as? [Any])?.count ?? -1) (requested \(((m as NSDictionary)["IOReportChannels"] as? [Any])?.count ?? -1))")
var samples: [[String: (Int32, Int64, String)]] = []
for i in 0..<2 {
    let s = IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue() as NSDictionary
    var d: [String: (Int32, Int64, String)] = [:]
    for c in (s["IOReportChannels"] as! [CFDictionary]) {
        let n = "\(str(IOReportChannelGetSubGroup(c)))/\(str(IOReportChannelGetChannelName(c)))"
        if let f = filter, !n.contains(f) { continue }
        let fmt = IOReportChannelGetFormat(c)
        var v: Int64 = 0
        if fmt == 1 { v = IOReportSimpleGetIntegerValue(c, 0) }
        else if fmt == 2 { for k in 0..<IOReportStateGetCount(c) { v += IOReportStateGetResidency(c, k) } }
        d[n] = (fmt, v, str(IOReportChannelGetUnitLabel(c)))
    }
    samples.append(d)
    if i == 0 { Thread.sleep(forTimeInterval: 1) }
}
var zero = 0, adv = 0, stat = 0
for k in samples[0].keys.sorted() {
    let (f, v0, u) = samples[0][k]!; let v1 = samples[1][k]?.1 ?? 0
    if v0 == 0 && v1 == 0 { zero += 1 } else if v1 != v0 { adv += 1 } else { stat += 1 }
    print("\(k) fmt=\(f) unit=\(u) raw0=\(v0) raw1=\(v1) delta=\(v1 - v0)")
}
print("summary: \(samples[0].count) channels; all-zero=\(zero) advancing=\(adv) static-nonzero=\(stat)")
