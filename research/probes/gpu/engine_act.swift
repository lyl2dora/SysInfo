// Probe: ANE / media-engine activity indicators (non-root), 1 line per sample
//  - PMP0 "AF BW" / "SOC-NI Util BW" / "SOC Floor" histograms (state format; events per bucket) for AGX/ANE/AVE/AVD/PRORES/MSR/JPEG
//  - Interrupt Statistics for ave0/avd0/apr0/jpeg/scaler/ane0 (each its own subscription; NULL -> reported)
//  - H11ANEIn IOPowerManagement.CurrentPowerState (IORegistry)
//  - Energy Model PMGR channels ANE0/AVE0/MSR0/ISP0 (to show whether they move)
// usage: engine_act <count> [intervalSec]
// build: xcrun swiftc -O -import-objc-header ioreport_bridge.h -o engine_act engine_act.swift -lIOReport -framework IOKit
import Foundation
import IOKit

func str(_ s: Unmanaged<CFString>?) -> String { (s?.takeUnretainedValue() as String?) ?? "" }
struct Sub { let name: String; let sub: IOReportSubscriptionRef; let ch: CFMutableDictionary; var prev: CFDictionary }
var subs: [Sub] = []
var failed: [String] = []
func add(_ g: String, _ s: String?) {
    guard let c = IOReportCopyChannelsInGroup(g as CFString, s as CFString?, 0, 0, 0)?.takeRetainedValue() else { failed.append("\(g)/\(s ?? "*"): no channels"); return }
    let m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, c)!
    var out: Unmanaged<CFMutableDictionary>?
    guard let sub = IOReportCreateSubscription(nil, m, &out, 0, nil), let sc = out?.takeRetainedValue() else { failed.append("\(g)/\(s ?? "*"): IOReportCreateSubscription NULL"); return }
    subs.append(Sub(name: "\(g)/\(s ?? "*")", sub: sub, ch: sc, prev: IOReportCreateSamples(sub, sc, nil)!.takeRetainedValue()))
}
add("PMP0", "AF BW"); add("PMP0", "SOC-NI Util BW"); add("PMP0", "SOC Floor"); add("Energy Model", nil)
for sg in ["ane0 0", "ane0 1", "ave0 0", "avd0 0", "avd0 1", "apr0 0", "apr0 1", "jpeg0 0", "jpeg1 0", "scaler0 0", "scaler1 0"] { add("Interrupt Statistics (by index)", sg) }
print("subscriptions ok: \(subs.map { $0.name })")
print("subscriptions FAILED: \(failed)")

func anePowerState() -> String {
    var it = io_iterator_t(); IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("H11ANEIn"), &it)
    var r: [String] = []
    while case let e = IOIteratorNext(it), e != 0 {
        if let pm = IORegistryEntryCreateCFProperty(e, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            r.append("\(pm["CurrentPowerState"] ?? "?")")
        }
        IOObjectRelease(e)
    }
    IOObjectRelease(it)
    return r.joined(separator: "/")
}
func bucketValue(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." }) ?? 0 }

let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 5
let interval = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1
let wantBW = ["AGX RD+WR", "ANE L0 RD+WR", "ANE L1 RD+WR", "AVD RD+WR", "MSR0 RD+WR", "MSR1 RD+WR", "PRORES RD+WR", "AVE0 RD+WR", "AVE1 RD+WR", "JPEG RD+WR"]
var prevT = Date()
for i in 0..<count {
    Thread.sleep(forTimeInterval: interval)
    let now = Date(); let dt = now.timeIntervalSince(prevT); prevT = now
    var bw: [String] = [], ni: [String] = [], floor: [String] = [], irq: [String: Int64] = [:], en: [String] = []
    for k in subs.indices {
        let cur = IOReportCreateSamples(subs[k].sub, subs[k].ch, nil)!.takeRetainedValue()
        let d = IOReportCreateSamplesDelta(subs[k].prev, cur, nil)!.takeRetainedValue() as NSDictionary
        subs[k].prev = cur
        for c in d["IOReportChannels"] as! [CFDictionary] {
            let sg = str(IOReportChannelGetSubGroup(c)), n = str(IOReportChannelGetChannelName(c))
            let fmt = IOReportChannelGetFormat(c)
            if fmt == 2 {
                var ev: Int64 = 0; var wsum = 0.0
                for s in 0..<IOReportStateGetCount(c) { let r = IOReportStateGetResidency(c, s); ev += r; wsum += Double(r) * bucketValue(str(IOReportStateGetNameForIndex(c, s))) }
                if sg == "AF BW" && wantBW.contains(n) && ev > 0 { bw.append(String(format: "%@:%.0fev/s~%.1f", n.replacingOccurrences(of: " RD+WR", with: ""), Double(ev) / dt, wsum / Double(ev))) }
                if sg == "SOC-NI Util BW" && ev > 0 && (n.contains("AVE") || n.contains("JPEG") || n.contains("ANE")) { ni.append(String(format: "%@:%.0fev/s", n, Double(ev) / dt)) }
                if sg == "SOC Floor" && ["AGX", "ANE", "AVE0", "AVE1", "AVD", "MSR0", "MSR1", "JPEG", "PRORES", "SCODEC", "ISP"].contains(n) {
                    // state 0 = no floor vote; report share of non-first states
                    var tot: Int64 = 0, nonFirst: Int64 = 0
                    for s in 0..<IOReportStateGetCount(c) { let r = IOReportStateGetResidency(c, s); tot += r; if s > 0 { nonFirst += r } }
                    if nonFirst > 0 { floor.append(String(format: "%@:%.0f%%", n, tot > 0 ? 100 * Double(nonFirst) / Double(tot) : 0)) }
                }
            } else if fmt == 1 {
                let v = IOReportSimpleGetIntegerValue(c, 0)
                if sg.contains(" ") && n.contains("First Level Interrupt Handler Count") { irq[sg.components(separatedBy: " ")[0], default: 0] += v }
                if subs[k].name.hasPrefix("Energy Model") && ["ANE0", "AVE0", "MSR0", "ISP0", "GPU Energy"].contains(n) {
                    en.append("\(n)=\(v)\(str(IOReportChannelGetUnitLabel(c)))")
                }
            }
        }
    }
    print(String(format: "[%d dt=%.2f] ANE_PS=%@ | IRQ/s ", i, dt, anePowerState()) + irq.sorted { $0.key < $1.key }.map { String(format: "%@=%.0f", $0.key, Double($0.value) / dt) }.joined(separator: " ")
          + " | AF_BW(ev/s~GB/s) " + bw.joined(separator: " ") + " | NI " + ni.joined(separator: " ") + " | FLOOR " + floor.joined(separator: " ") + " | EM " + en.joined(separator: " "))
    fflush(stdout)
}
