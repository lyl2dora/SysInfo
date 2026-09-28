// Probe: Stats' GPU reader path (IOAccelerator PerformanceStatistics, AGCInfo, IOPCIDevice "display")
// build: xcrun swiftc -O -o accel_stats accel_stats.swift -framework IOKit
import Foundation
import IOKit

func services(_ cls: String) -> [(io_registry_entry_t, NSDictionary)] {
    var it = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return [] }
    var out: [(io_registry_entry_t, NSDictionary)] = []
    while case let e = IOIteratorNext(it), e != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let p = props?.takeRetainedValue() {
            out.append((e, p as NSDictionary))
        }
    }
    IOObjectRelease(it)
    return out
}

let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 5 : 5
let pci = services("IOPCIDevice").filter { ($0.1["IOName"] as? String) == "display" }
print("IOPCIDevice with IOName==display (Stats setup path): \(pci.count)")

let accs = services("IOAccelerator")   // kIOAcceleratorClassName
print("IOAccelerator services: \(accs.count)")
for (_, a) in accs {
    print("IOClass=\(a["IOClass"] ?? "nil") model=\(a["model"] ?? "nil") gpu-core-count=\(a["gpu-core-count"] ?? "nil") IONameMatched=\(a["IONameMatched"] ?? "nil")")
    print("  IOPCIMatch=\(a["IOPCIMatch"] ?? "nil") IOPCIPrimaryMatch=\(a["IOPCIPrimaryMatch"] ?? "nil")")
    print("  AGCInfo=\(a["AGCInfo"] ?? "nil")  (Stats reads AGCInfo.poweredOffByAGC)")
    print("  GPUConfigurationVariable=\(a["GPUConfigurationVariable"] ?? "nil")")
    if let ps = a["PerformanceStatistics"] as? [String: Any] {
        print("  PerformanceStatistics keys: \(ps.keys.sorted())")
        let statsKeys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %", "Tiler Utilization %", "Temperature(C)", "Fan Speed(%)", "Core Clock(MHz)", "Memory Clock(MHz)"]
        for k in statsKeys { print("    Stats key '\(k)': \(ps[k].map { "\($0)" } ?? "ABSENT")") }
    }
}
print("--- time series (\(n) samples @1s): device/renderer/tiler %, in-use sysmem, alloc sysmem, driver sysmem")
for i in 0..<n {
    for (_, a) in services("IOAccelerator") {
        if let ps = a["PerformanceStatistics"] as? [String: Any] {
            let f = { (k: String) in (ps[k] as? NSNumber)?.int64Value ?? -1 }
            print(String(format: "t=%d dev=%lld%% ren=%lld%% til=%lld%% inuse=%.1fMB alloc=%.1fMB drv=%lld TiledSceneBytes=%lld AllocPB=%lld recovery=%lld",
                         i, f("Device Utilization %"), f("Renderer Utilization %"), f("Tiler Utilization %"),
                         Double(f("In use system memory"))/1048576, Double(f("Alloc system memory"))/1048576, f("In use system memory (driver)"),
                         f("TiledSceneBytes"), f("Allocated PB Size"), f("recoveryCount")))
        }
    }
    if i < n - 1 { Thread.sleep(forTimeInterval: 1) }
}
