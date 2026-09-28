// Probe: time series of absolute IOReport simple-channel values (update cadence check)
// usage: ior_series <group> <subgroup|-> <comma-separated channel names> <periodSec> <count>
// build: xcrun swiftc -O -import-objc-header ioreport_bridge.h -o ior_series ior_series.swift -lIOReport
import Foundation

let a = CommandLine.arguments
let group = a[1]
let subgroup: String? = a[2] == "-" ? nil : a[2]
let names = a[3].components(separatedBy: ",")
let period = Double(a[4])!
let count = Int(a[5])!
func str(_ s: Unmanaged<CFString>?) -> String { (s?.takeUnretainedValue() as String?) ?? "" }

let ch = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)!.takeRetainedValue()
let m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch)!
var subbed: Unmanaged<CFMutableDictionary>?
let sub = IOReportCreateSubscription(nil, m, &subbed, 0, nil)!
let sc = subbed!.takeRetainedValue()
let t0 = Date()
var last: [String: Int64] = [:]
print("t(s)\t" + names.joined(separator: "\t"))
for _ in 0..<count {
    let s = IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue() as NSDictionary
    var row: [String: Int64] = [:]
    for c in (s["IOReportChannels"] as! [CFDictionary]) {
        let n = str(IOReportChannelGetChannelName(c))
        if names.contains(n) { row[n] = IOReportSimpleGetIntegerValue(c, 0) }
    }
    let t = Date().timeIntervalSince(t0)
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium); print(ts + "\t" + String(format: "%.2f\t", t) + names.map { n in
        let v = row[n] ?? -1
        let d = last[n].map { v - $0 } ?? 0
        last[n] = v
        return "\(v)(+\(d))"
    }.joined(separator: "\t"))
    fflush(stdout); Thread.sleep(forTimeInterval: period)
}
