// Probe: dump state-format channel residency deltas for a group/subgroup over an interval
// usage: ior_states <group> <subgroup|-> <intervalSec> [nameFilter]
// build: xcrun swiftc -O -import-objc-header ioreport_bridge.h -o ior_states ior_states.swift -lIOReport
import Foundation

let a = CommandLine.arguments
let group = a[1]
let subgroup: String? = a[2] == "-" ? nil : a[2]
let interval = Double(a[3])!
let filter: String? = a.count > 4 ? a[4] : nil
func str(_ s: Unmanaged<CFString>?) -> String { (s?.takeUnretainedValue() as String?) ?? "" }

let ch = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)!.takeRetainedValue()
let m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch)!
var subbed: Unmanaged<CFMutableDictionary>?
guard let sub = IOReportCreateSubscription(nil, m, &subbed, 0, nil) else { print("IOReportCreateSubscription NULL"); exit(1) }
let sc = subbed!.takeRetainedValue()
let s0 = IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue()
Thread.sleep(forTimeInterval: interval)
let s1 = IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue()
let d = IOReportCreateSamplesDelta(s0, s1, nil)!.takeRetainedValue() as NSDictionary
for c in (d["IOReportChannels"] as! [CFDictionary]) {
    let n = "\(str(IOReportChannelGetSubGroup(c)))/\(str(IOReportChannelGetChannelName(c)))"
    if let f = filter, !n.contains(f) { continue }
    let fmt = IOReportChannelGetFormat(c)
    if fmt == 2 {
        let k = IOReportStateGetCount(c)
        let st = (0..<k).map { "\(str(IOReportStateGetNameForIndex(c, $0)))=\(IOReportStateGetResidency(c, $0))" }
        print("\(n) [state x\(k), unit \(str(IOReportChannelGetUnitLabel(c)))]: \(st.joined(separator: " "))")
    } else if fmt == 1 {
        print("\(n) [simple, unit \(str(IOReportChannelGetUnitLabel(c)))]: \(IOReportSimpleGetIntegerValue(c, 0))")
    } else {
        print("\(n) [format \(fmt)]")
    }
}
