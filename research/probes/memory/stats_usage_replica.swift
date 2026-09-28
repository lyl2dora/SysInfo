// stats_usage_replica.swift - verbatim replica of Stats UsageReader.setup()/read() (Modules/RAM/readers.swift:18-99) built with the macOS 27 SDK
import Foundation
import Darwin
var basic = host_basic_info()
var bcount = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
_ = withUnsafeMutablePointer(to: &basic) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) { host_info(mach_host_self(), HOST_BASIC_INFO, $0, &bcount) } }
let totalSize = Double(basic.max_mem)
func read() {
    var stats = vm_statistics64()
    var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let requested = count
    let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
    let ps = Double(vm_page_size)
    let active = Double(stats.active_count) * ps, speculative = Double(stats.speculative_count) * ps, inactive = Double(stats.inactive_count) * ps
    let wired = Double(stats.wire_count) * ps, compressed = Double(stats.compressor_page_count) * ps, purgeable = Double(stats.purgeable_count) * ps
    let external = Double(stats.external_page_count) * ps
    let used = active + inactive + speculative + wired + compressed - purgeable - external
    let free = totalSize - used
    var intSize: size_t = MemoryLayout<uint>.size; var pressureLevel: Int = 0
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &intSize, nil, 0)
    var stringSize: size_t = MemoryLayout<xsw_usage>.size; var swap = xsw_usage()
    sysctlbyname("vm.swapusage", &swap, &stringSize, nil, 0)
    let G = 1073741824.0
    print(String(format: "kr=%d count req=%u ret=%u sizeof=%d vm_page_size=%.0f | total=%.2fG used=%.2fG free=%.2fG app=%.2fG wired=%.2fG compressed=%.2fG cache=%.2fG usage=%.1f%% pressure=%d swapUsed=%.0f swapins=%llu swapouts=%llu",
        result, requested, count, MemoryLayout<vm_statistics64>.size, ps, totalSize/G, used/G, free/G, (used-wired-compressed)/G, wired/G, compressed/G, (purgeable+external)/G, used/totalSize*100, pressureLevel, Double(swap.xsu_used), stats.swapins, stats.swapouts))
}
read(); Thread.sleep(forTimeInterval: 1); read()
