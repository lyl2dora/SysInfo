// pressure_probe.swift - memory pressure level, memorystatus level, swap usage, DispatchSource memory-pressure source
import Foundation
import Darwin

func sysctlInt32(_ name: String) -> (Int32, Int32, Int) {
    var v: Int32 = -1; var sz = MemoryLayout<Int32>.size
    let rc = sysctlbyname(name, &v, &sz, nil, 0)
    return (rc, rc == 0 ? v : errno, sz)
}

// 1. Stats' exact pattern (Modules/RAM/readers.swift:61-63): Int (8 bytes) buffer with size = MemoryLayout<uint>.size (4)
var intSize: size_t = MemoryLayout<UInt32>.size
var pressureLevel: Int = 0
let rcStats = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &intSize, nil, 0)
print("Stats-pattern kern.memorystatus_vm_pressure_level rc=\(rcStats) value=\(pressureLevel) outsize=\(intSize)")
// what if the buffer size is passed as 8 (common bug)?
var sz8: size_t = 8; var lvl8: Int = 0
let rc8 = sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl8, &sz8, nil, 0)
print("8-byte buffer: rc=\(rc8) value=\(lvl8) outsize=\(sz8)")

for n in ["kern.memorystatus_vm_pressure_level", "kern.memorystatus_level", "vm.memory_pressure",
          "kern.vm_pressure_level_transition_threshold", "kern.memorystatus_purge_on_warning",
          "kern.memorystatus_purge_on_urgent", "kern.memorystatus_purge_on_critical"] {
    let (rc, v, sz) = sysctlInt32(n)
    print("\(n): rc=\(rc) value=\(v) size=\(sz)")
}

// 2. swap: vm.swapusage -> xsw_usage
var swap = xsw_usage(); var ssz = MemoryLayout<xsw_usage>.size
let rcs = sysctlbyname("vm.swapusage", &swap, &ssz, nil, 0)
print("vm.swapusage rc=\(rcs) size=\(ssz) total=\(swap.xsu_total) avail=\(swap.xsu_avail) used=\(swap.xsu_used) pagesize=\(swap.xsu_pagesize) encrypted=\(swap.xsu_encrypted)")
for n in ["vm.swap_enabled", "vm.compressor.mode", "vm.compressor.swapper.swapfile_cnt"] {
    let (rc, v, _) = sysctlInt32(n); print("\(n): rc=\(rc) value=\(v)")
}
func sysctlU64(_ n: String) -> UInt64? { var v: UInt64 = 0; var s = 8; return sysctlbyname(n, &v, &s, nil, 0) == 0 ? (s == 4 ? UInt64(UInt32(truncatingIfNeeded: v)) : v) : nil }
for n in ["vm.compressor_input_bytes", "vm.compressor_compressed_bytes", "vm.compressor_bytes_used",
          "vm.compressor.pages_compressed", "vm.compressor.swapper.used_bytes", "vm.compressor.swapper.allocated_bytes", "vm.vm_ecc_corrected_count", "vm.vm_ecc_uncorrected_count", "hw.memsize_usable"] {
    print("\(n) = \(sysctlU64(n).map(String.init) ?? "ERR errno=\(errno)")")
}
if let inB = sysctlU64("vm.compressor_input_bytes"), let outB = sysctlU64("vm.compressor_compressed_bytes"), outB > 0 {
    print(String(format: "compressor ratio (input/compressed bytes) = %.2f", Double(inB)/Double(outB)))
}

// 3. task_vm_info for self
var vmi = task_vm_info_data_t(); var cnt = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
let kr = withUnsafeMutablePointer(to: &vmi) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &cnt) } }
print("task_info(TASK_VM_INFO self) kr=\(kr) phys_footprint=\(vmi.phys_footprint) resident=\(vmi.resident_size) count=\(cnt)")

// 4. DispatchSource memory pressure
let q = DispatchQueue(label: "mp")
let src = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: q)
var events = 0
src.setEventHandler { events += 1; print("memory pressure event: data=\(src.data)") }
src.setRegistrationHandler { print("memory pressure source registered (mask=.all); isCancelled=\(src.isCancelled)") }
src.activate()
Thread.sleep(forTimeInterval: 3)
print("after 3s: events=\(events) src.data=\(src.data.rawValue) (no event expected at steady normal pressure)")
src.cancel()
