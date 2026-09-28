// Probe: IOReport sampler for GPU / ANE / media engines / display swaps.
// usage: ior_sample <intervalSec> <count> [verbose]
// build: xcrun swiftc -O -import-objc-header ioreport_bridge.h -o ior_sample ior_sample.swift -lIOReport -framework IOKit
import Foundation
import IOKit

let args = CommandLine.arguments
let interval = args.count > 1 ? Double(args[1])! : 1.0
let count = args.count > 2 ? Int(args[2])! : 3
let verbose = args.count > 3

// ---- GPU DVFS table from pmgr voltage-states9 (Hz, mV pairs) ----
func gpuFreqTableMHz() -> [Double] {
    var it = io_iterator_t()
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it)
    defer { IOObjectRelease(it) }
    while case let e = IOIteratorNext(it), e != 0 {
        defer { IOObjectRelease(e) }
        var name = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(e, &name)
        guard String(cString: name) == "pmgr" else { continue }
        guard let d = IORegistryEntryCreateCFProperty(e, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return [] }
        return d.withUnsafeBytes { raw in (0..<(raw.count / 8)).map { Double(raw.load(fromByteOffset: $0 * 8, as: UInt32.self)) / 1e6 } }
    }
    return []
}
let gpuTable = gpuFreqTableMHz()
print("GPU DVFS (voltage-states9) MHz: \(gpuTable.map { Int($0) })")

// ---- build subscription ----
func copy(_ g: String, _ s: String?) -> CFDictionary? {
    IOReportCopyChannelsInGroup(g as CFString, s as CFString?, 0, 0, 0)?.takeRetainedValue()
}
var parts: [CFDictionary] = []
for (g, s) in [("Energy Model", nil), ("GPU Stats", nil), ("AMC Stats", "Perf Counters"),
               ("DCPEXT0", "swap"), ("DCPEXT1", "swap"), ("DCPEXT2", "swap"), ("DCPEXT3", "swap"), ("DCP", "swap"),
               ("DCPEXT0", "display stats"), ("DCPEXT1", "display stats"), ("DCPEXT2", "display stats"), ("DCPEXT3", "display stats")] as [(String, String?)] {
    if let c = copy(g, s) { parts.append(c) } else if verbose { print("no channels for \(g)/\(s ?? "*")") }
}
for sg in ["ane0 0", "ane0 1", "ave0 0", "avd0 0", "avd0 1", "apr0 0", "apr0 1", "jpeg0 0", "jpeg1 0", "scaler0 0", "scaler1 0", "gfx-asc 1", "gfx1-asc 1"] {
    if let c = copy("Interrupt Statistics (by index)", sg) { parts.append(c) }
}
let merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, parts[0])!
for p in parts.dropFirst() { IOReportMergeChannels(merged, p, nil) }
var subbed: Unmanaged<CFMutableDictionary>?
guard let sub = IOReportCreateSubscription(nil, merged, &subbed, 0, nil) else { print("IOReportCreateSubscription failed"); exit(1) }
let subChannels = subbed!.takeRetainedValue()

func toJoules(_ v: Int64, _ unit: String) -> Double {
    switch unit.trimmingCharacters(in: .whitespaces).lowercased() {
    case "mj": return Double(v) / 1e3
    case "uj", "µj": return Double(v) / 1e6
    case "nj": return Double(v) / 1e9
    case "pj": return Double(v) / 1e12
    default: return Double(v) / 1e9
    }
}
func str(_ s: Unmanaged<CFString>?) -> String { (s?.takeUnretainedValue() as String?) ?? "" }

var prev = IOReportCreateSamples(sub, subChannels, nil)!.takeRetainedValue()
var prevT = Date()
for iter in 0..<count {
    Thread.sleep(forTimeInterval: interval)
    let cur = IOReportCreateSamples(sub, subChannels, nil)!.takeRetainedValue()
    let now = Date(); let dt = now.timeIntervalSince(prevT)
    let delta = IOReportCreateSamplesDelta(prev, cur, nil)!.takeRetainedValue() as NSDictionary
    prev = cur; prevT = now
    let items = delta["IOReportChannels"] as! [CFDictionary]

    var watts: [String: Double] = [:]
    var amc: [String: Double] = [:]
    var irq: [String: Int64] = [:]
    var swaps: [String: Int64] = [:]
    var frameCount: [String: Int64] = [:]
    var gpuph: [(String, Int64)] = []
    var otherStates: [String: [(String, Int64)]] = [:]
    var simpleGPU: [String: Int64] = [:]

    for ch in items {
        let g = str(IOReportChannelGetGroup(ch)), sg = str(IOReportChannelGetSubGroup(ch)), n = str(IOReportChannelGetChannelName(ch))
        let unit = str(IOReportChannelGetUnitLabel(ch))
        let fmt = IOReportChannelGetFormat(ch)
        switch g {
        case "Energy Model":
            if n.contains("DTL") || n.hasPrefix("MCPU") && n.contains("_") { continue }
            watts[n, default: 0] += toJoules(IOReportSimpleGetIntegerValue(ch, 0), unit) / dt
        case "AMC Stats":
            if n.hasPrefix("PRIM ") { amc[n] = Double(IOReportSimpleGetIntegerValue(ch, 0)) / dt / 1e6 }
        case "Interrupt Statistics (by index)":
            if n.contains("First Level Interrupt Handler Count") { irq[sg.components(separatedBy: " ").first!, default: 0] += IOReportSimpleGetIntegerValue(ch, 0) }
        case "GPU Stats":
            if fmt == 2 {
                var st: [(String, Int64)] = []
                for i in 0..<IOReportStateGetCount(ch) { st.append((str(IOReportStateGetNameForIndex(ch, i)), IOReportStateGetResidency(ch, i))) }
                if sg == "GPU Performance States" { gpuph = st } else { otherStates["\(sg)/\(n)"] = st }
            } else if fmt == 1 {
                simpleGPU["\(sg)/\(n)"] = IOReportSimpleGetIntegerValue(ch, 0)
            }
        default:
            if g.hasPrefix("DCP") && sg == "swap" { swaps[g, default: 0] += IOReportSimpleGetIntegerValue(ch, 0) }
            if g.hasPrefix("DCP") && sg == "display stats" && n == "frame_count" { frameCount[g, default: 0] += IOReportSimpleGetIntegerValue(ch, 0) }
        }
    }

    print(String(format: "===== sample %d  dt=%.3fs", iter, dt))
    let order = ["GPU Energy", "GPU0", "AFR0", "ANE0", "AVE0", "ISP0", "MSR0", "DISP0", "DISPEXT0", "DRAM0", "DCS0", "FAB0", "AMCC0", "CPU Energy"]
    print("  power W: " + order.compactMap { k in watts[k].map { String(format: "%@=%.3f", k, $0) } }.joined(separator: " "))
    if verbose { print("  other energy: " + watts.filter { !order.contains($0.key) }.sorted { $0.key < $1.key }.map { String(format: "%@=%.3f", $0.key, $0.value) }.joined(separator: " ")) }

    // GPUPH residency -> active %, average active frequency
    let total = gpuph.reduce(0) { $0 + $1.1 }
    if total > 0 {
        let offIdx = gpuph.firstIndex { $0.0 == "OFF" || $0.0 == "IDLE" || $0.0 == "DOWN" }
        let offRes = offIdx.map { gpuph[$0].1 } ?? 0
        let active = total - offRes
        // map active states (all but OFF) to DVFS table entries 1..N
        var fsum = 0.0
        var activeStates: [String] = []
        var k = 0
        for (i, s) in gpuph.enumerated() where i != offIdx {
            k += 1
            let f = k < gpuTable.count ? gpuTable[k] : 0
            fsum += Double(s.1) * f
            if s.1 > 0 { activeStates.append(String(format: "%@(%.0fMHz)=%.1f%%", s.0, f, 100 * Double(s.1) / Double(total))) }
        }
        print(String(format: "  GPUPH: %d states, names=%@ | active(non-OFF) residency=%.1f%% avgFreq(active)=%.0f MHz | ticks total=%lld (%.2fs @24MHz)",
                     gpuph.count, gpuph.map { $0.0 }.joined(separator: ","), 100 * Double(active) / Double(total), active > 0 ? fsum / Double(active) : 0, total, Double(total) / 24e6))
        if !activeStates.isEmpty { print("    active states: " + activeStates.joined(separator: " ")) }
    } else { print("  GPUPH: no residency (total=0) states=\(gpuph.map { $0.0 })") }
    for key in ["GPU Boost Controller Performance States/BSTGPUPH", "CLTM-induced GPU Performance States/GPU_CLTM", "AFR Performance States/AFRSTATE", "GPU Power Controller States/PWRCTRL", "PPM Target as % of Max GPU Power/GPU_PPM", "Fender State/FENDER"] {
        if let st = otherStates[key] {
            let t = st.reduce(0) { $0 + $1.1 }
            let nz = st.filter { $0.1 > 0 }.map { String(format: "%@=%.1f%%", $0.0, t > 0 ? 100 * Double($0.1) / Double(t) : 0) }
            print("  \(key) [\(st.count) states]: \(nz.joined(separator: " "))")
        }
    }
    if verbose {
        for (k, st) in otherStates.sorted(by: { $0.key < $1.key }) {
            print("    state \(k): " + st.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        }
        print("  GPU simple counters (delta): " + simpleGPU.filter { $0.value != 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
    }
    let amcKeys = ["GFX", "GFXC", "ANE", "ANEXL", "AVE0", "AVE1", "AVD", "PRORES1", "JPEG", "MSR0", "MSR1", "SCODEC", "ISP"]
    print("  AMC MB/s (DCS RD+WR | AF RD+WR): " + amcKeys.map { k in
        let dcs = (amc["PRIM \(k) DCS RD"] ?? 0) + (amc["PRIM \(k) DCS WR"] ?? 0)
        let af = (amc["PRIM \(k) AF RD"] ?? 0) + (amc["PRIM \(k) AF WR"] ?? 0)
        return String(format: "%@=%.1f|%.1f", k, dcs, af)
    }.joined(separator: " "))
    print(String(format: "  AMC total DCS RD=%.1f WR=%.1f MB/s", amc["PRIM DCS RD"] ?? 0, amc["PRIM DCS WR"] ?? 0))
    print("  IRQ/s: " + irq.sorted { $0.key < $1.key }.map { String(format: "%@=%.0f", $0.key, Double($0.value) / dt) }.joined(separator: " "))
    print("  DCP swap/s: " + swaps.sorted { $0.key < $1.key }.map { String(format: "%@=%.1f", $0.key, Double($0.value) / dt) }.joined(separator: " ")
          + " | frame_count/s: " + frameCount.sorted { $0.key < $1.key }.map { String(format: "%@=%.1f", $0.key, Double($0.value) / dt) }.joined(separator: " "))
}
