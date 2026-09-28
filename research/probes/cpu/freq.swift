// Probe: per-core / per-cluster CPU frequency on M5 Pro from IOReport "CPU Stats" residencies + pmgr voltage-states*-sram DVFS tables.
// (1) replicates Stats FrequencyReader (Modules/CPU/readers.swift:307-538 + Kit/plugins/SystemKit.swift:493-533) exactly
// (2) improved: per-channel table chosen by DVFS-state count, per-core & per-cluster average active frequency + active residency.
import Foundation
import IOKit
import Synchronization

// --- DVFS tables from pmgr
func pmgrTables() -> [String: [Int]] {
    var it: io_iterator_t = 0; var out: [String: [Int]] = [:]
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it)
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        var nb = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(s, &nb)
        guard String(cString: nb) == "pmgr" else { continue }
        var p: Unmanaged<CFMutableDictionary>?; IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0)
        for (k, v) in (p?.takeRetainedValue() as? [String: Any]) ?? [:] where k.hasPrefix("voltage-states") && k.hasSuffix("-sram") {
            guard let d = v as? Data else { continue }
            var f: [Int] = []; d.withUnsafeBytes { r in var o = 0; while o + 8 <= d.count { f.append(Int(r.load(fromByteOffset: o, as: UInt32.self)) / 1000); o += 8 } }
            out[k] = f
        }
    }
    IOObjectRelease(it); return out
}
let tables = pmgrTables()
print("pmgr *-sram tables:", tables.keys.sorted().map { "\($0)[\(tables[$0]!.count)] \(tables[$0]!.first ?? 0)-\(tables[$0]!.last ?? 0)MHz" })
let statsE = tables["voltage-states1-sram"] ?? [], statsP = tables["voltage-states22-sram"] ?? [], statsS = tables["voltage-states5-sram"] ?? []
print("Stats M5 mapping: e=voltage-states1-sram \(statsE.isEmpty ? "ABSENT" : "\(statsE.count)") p(M)=voltage-states22-sram[\(statsP.count)] s=voltage-states5-sram[\(statsS.count)]")

// --- IOReport subscription (same as Stats)
let a = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)!.takeRetainedValue()
let b = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)!.takeRetainedValue()
IOReportMergeChannels(a, b, nil)
var subbed: Unmanaged<CFMutableDictionary>?
let sub = IOReportCreateSubscription(nil, a, &subbed, 0, nil)
let subDict = subbed!.takeRetainedValue()

struct Ch { let sub: String; let name: String; let states: [(String, Int64)] }
func delta(_ secs: Double) -> [Ch] {
    let s1 = IOReportCreateSamples(sub, subDict, nil)!.takeRetainedValue()
    Thread.sleep(forTimeInterval: secs)
    let s2 = IOReportCreateSamples(sub, subDict, nil)!.takeRetainedValue()
    let d = IOReportCreateSamplesDelta(s1, s2, nil)!.takeRetainedValue() as! [String: Any]
    return (d["IOReportChannels"] as! [CFDictionary]).map { c in
        let n = IOReportStateGetCount(c)
        return Ch(sub: IOReportChannelGetSubGroup(c)!.takeUnretainedValue() as String, name: IOReportChannelGetChannelName(c)!.takeUnretainedValue() as String,
                  states: (0..<n).map { (IOReportStateGetNameForIndex(c, $0)!.takeUnretainedValue() as String, IOReportStateGetResidency(c, $0)) })
    }
}
// Stats' calculateFrequencies (readers.swift:420-435) verbatim logic
func statsCalc(_ items: [(String, Int64)], _ freqs: [Int]) -> Double {
    guard let offset = items.firstIndex(where: { $0.0 != "IDLE" && $0.0 != "DOWN" && $0.0 != "OFF" }) else { return 0 }
    let usage = items.dropFirst(offset).reduce(0.0) { $0 + Double($1.1) }
    var avg = 0.0
    for i in 0..<freqs.count { let k = i + offset; if !items.indices.contains(k) { continue }; avg += (usage == 0 ? 0 : Double(items[k].1) / usage) * Double(freqs[i]) }
    return avg
}
// Improved: parse "V<i>P<j>" -> DVFS index i; choose table by count of V-states
func better(_ items: [(String, Int64)]) -> (mhz: Double, active: Double, table: String) {
    let v = items.compactMap { (n, r) -> (Int, Int64)? in
        guard n.hasPrefix("V"), let p = n.firstIndex(of: "P"), let i = Int(n[n.index(after: n.startIndex)..<p]) else { return nil }; return (i, r) }
    let tot = items.reduce(Int64(0)) { $0 + $1.1 }
    let act = v.reduce(Int64(0)) { $0 + $1.1 }
    guard let (tk, t) = tables.first(where: { $0.value.count == v.count }) else { return (0, 0, "no-table-for-\(v.count)") }
    let mhz = act == 0 ? 0 : v.reduce(0.0) { $0 + Double($1.1) * Double(t[$1.0]) } / Double(act)
    return (mhz, tot == 0 ? 0 : Double(act) / Double(tot), tk)
}
func report(_ title: String, _ chs: [Ch]) {
    print("\n=== \(title) ===")
    // Stats replication (sCoreCount != 0 on this Mac -> pCore uses "MCPU", sCore uses "PCPU")
    var p: [Double] = [], s: [Double] = [], e: [Double] = []
    for c in chs {
        if c.name.contains("ECPU") { e.append(statsCalc(c.states, statsE)) }
        if c.name.contains("MCPU") { p.append(statsCalc(c.states, statsP)) }
        if c.name.contains("PCPU") { s.append(statsCalc(c.states, statsS)) }
    }
    let pf = max(p.reduce(0, +) / Double(max(p.count, 1)), Double(statsP.min() ?? 0)), sf = max(s.reduce(0, +) / Double(max(s.count, 1)), Double(statsS.min() ?? 0))
    print(String(format: "Stats algorithm: E=%@ P(M, %d channels)=%.0f MHz  S(%d channels)=%.0f MHz  overall=%.0f MHz", e.isEmpty ? "nil (no ECPU channels)" : "?", p.count, pf, s.count, sf, (pf * 12 + sf * 6) / 18))
    for c in chs {
        let r = better(c.states)
        print(String(format: "  [%@] %-8@ active=%5.1f%% avgActiveFreq=%6.0f MHz  table=%@", c.sub == "CPU Core Performance States" ? "core" : "cplx", c.name, 100 * r.active, r.mhz, r.table))
    }
}
report("IDLE 1s", delta(1))
let stop = Atomic<Bool>(false)
nonisolated(unsafe) var sink = 0.0
for _ in 0..<18 { Thread { var x = 1.0; while !stop.load(ordering: .relaxed) { for _ in 0..<1000 { x = x * 1.0000001 + 0.5 } }; sink += x }.start() }
Thread.sleep(forTimeInterval: 0.3)
report("LOADED 1s (18 spinning threads)", delta(1))
stop.store(true, ordering: .relaxed)
Thread.sleep(forTimeInterval: 0.3)
for _ in 0..<6 { let t = Thread { var x = 1.0; while !stop.load(ordering: .relaxed) { for _ in 0..<1000 { x = x * 1.0000001 + 0.5 } }; sink += x }; t.qualityOfService = .background; t.start() }
stop.store(false, ordering: .relaxed)
Thread.sleep(forTimeInterval: 0.3)
report("LOADED 1s (6 threads QoS background)", delta(1))
stop.store(true, ordering: .relaxed)
