// Probe: per-process GPU time from AGXDeviceUserClient children of the IOAccelerator
// ("IOUserClientCreator" = "pid N, name", "AppUsage" = [{API, accumulatedGPUTime, lastSubmittedTime}])
// usage: gpu_procs <intervalSec> [top]
// build: xcrun swiftc -O -o gpu_procs gpu_procs.swift -framework IOKit
import Foundation
import IOKit

struct Usage { var name: String; var gpuNs: UInt64; var clients: Int; var apis: Set<String>; var lastSubmitted: UInt64 }

func snapshot() -> [Int: Usage] {
    var out: [Int: Usage] = [:]
    var it = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(it) }
    while case let acc = IOIteratorNext(it), acc != 0 {
        defer { IOObjectRelease(acc) }
        var kids = io_iterator_t()
        guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids) == KERN_SUCCESS else { continue }
        defer { IOObjectRelease(kids) }
        while case let c = IOIteratorNext(kids), c != 0 {
            defer { IOObjectRelease(c) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(c, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any],
                  let creator = d["IOUserClientCreator"] as? String else { continue }
            // "pid 172, WindowServer"
            let parts = creator.components(separatedBy: ", ")
            guard let pid = Int(parts[0].replacingOccurrences(of: "pid ", with: "")) else { continue }
            let name = parts.dropFirst().joined(separator: ", ")
            var u = out[pid] ?? Usage(name: name, gpuNs: 0, clients: 0, apis: [], lastSubmitted: 0)
            u.clients += 1
            for app in (d["AppUsage"] as? [[String: Any]]) ?? [] {
                u.gpuNs += (app["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                u.lastSubmitted = max(u.lastSubmitted, (app["lastSubmittedTime"] as? NSNumber)?.uint64Value ?? 0)
                if let api = app["API"] as? String { u.apis.insert(api) }
            }
            out[pid] = u
        }
    }
    return out
}

let interval = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 2
let top = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 10
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
print("timebase \(tb.numer)/\(tb.denom); mach_absolute_time=\(mach_absolute_time()) mach_continuous_time=\(mach_continuous_time()) uptime_raw_ns=\(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) monotonic_raw_ns=\(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))")
let t0 = Date(); let a = snapshot()
Thread.sleep(forTimeInterval: interval)
let b = snapshot(); let dt = Date().timeIntervalSince(t0)
print("processes with AGX user clients: \(b.count); user clients total: \(b.values.reduce(0) { $0 + $1.clients })")
let maxLast = b.values.map { $0.lastSubmitted }.max() ?? 0
print("max lastSubmittedTime=\(maxLast)")
var rows: [(Int, Usage, Double)] = []
for (pid, u) in b {
    let prev = a[pid]?.gpuNs ?? u.gpuNs
    let d = u.gpuNs >= prev ? Double(u.gpuNs - prev) : 0
    rows.append((pid, u, d / (dt * 1e9) * 100))
}
rows.sort { $0.2 == $1.2 ? $0.1.gpuNs > $1.1.gpuNs : $0.2 > $1.2 }
print(String(format: "interval %.2fs. top %d by GPU%% (delta accumulatedGPUTime / wall):", dt, top))
for (pid, u, pct) in rows.prefix(top) {
    print(String(format: "  pid %6d %-28@ GPU %6.2f%%  total %10.2fs  clients %d  apis %@", pid, u.name as NSString, pct, Double(u.gpuNs) / 1e9, u.clients, u.apis.sorted().joined(separator: ",") as NSString))
}
