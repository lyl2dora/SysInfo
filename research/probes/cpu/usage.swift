// Probe: total + per-core CPU usage via host_processor_info / host_statistics(HOST_CPU_LOAD_INFO);
// plus mapping check: spin N threads at a given QoS and see which logical CPU indices light up.
import Foundation
import Darwin
import Synchronization
let stopFlag = Atomic<Bool>(false)
nonisolated(unsafe) var sink: Double = 0

func perCoreTicks() -> [[UInt32]] {
    var n: natural_t = 0; var info: processor_info_array_t?; var cnt: mach_msg_type_number_t = 0
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)
    guard kr == KERN_SUCCESS, let info else { print("host_processor_info kr=\(kr)"); return [] }
    var out: [[UInt32]] = []
    for i in 0..<Int(n) {
        let b = Int(CPU_STATE_MAX) * i
        out.append([UInt32(bitPattern: info[b+Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b+Int(CPU_STATE_SYSTEM)]), UInt32(bitPattern: info[b+Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b+Int(CPU_STATE_NICE)])])
    }
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(cnt) * MemoryLayout<integer_t>.stride))
    return out
}
func hostLoad() -> host_cpu_load_info {
    var li = host_cpu_load_info(); var c = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &li) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &c) } }
    if kr != KERN_SUCCESS { print("host_statistics kr=\(kr)") }
    return li
}
func pct(_ a: [[UInt32]], _ b: [[UInt32]]) -> [String] {
    zip(a, b).map { p, q in
        let u = q[0] &- p[0], s = q[1] &- p[1], i = q[2] &- p[2], n = q[3] &- p[3]
        let tot = Double(u) + Double(s) + Double(i) + Double(n)
        return tot == 0 ? "  - " : String(format: "%3.0f%%", 100 * (Double(u) + Double(s) + Double(n)) / tot)
    }
}
// cluster labels from IORegistry order (probe topology.txt): cpu0-11 = M ("Performance"), cpu12-17 = P ("Super")
let labels = (0..<18).map { $0 < 12 ? "M\($0)" : "S\($0)" }
print("host_processor_info count:", perCoreTicks().count, " clock ticks/s (sysconf _SC_CLK_TCK):", sysconf(Int32(_SC_CLK_TCK)))
print("idx:  " + labels.map { $0.padding(toLength: 4, withPad: " ", startingAt: 0) }.joined(separator: " "))

func measure(_ title: String, _ secs: Double = 1.0) {
    let a = perCoreTicks(); let la = hostLoad()
    Thread.sleep(forTimeInterval: secs)
    let b = perCoreTicks(); let lb = hostLoad()
    let du = Double(lb.cpu_ticks.0 &- la.cpu_ticks.0), ds = Double(lb.cpu_ticks.1 &- la.cpu_ticks.1), di = Double(lb.cpu_ticks.2 &- la.cpu_ticks.2), dn = Double(lb.cpu_ticks.3 &- la.cpu_ticks.3)
    let t = du + ds + di + dn
    print("\(title)\n  per-core: " + pct(a, b).joined(separator: " "))
    print(String(format: "  HOST_CPU_LOAD_INFO: user=%.1f%% sys=%.1f%% idle=%.1f%% nice=%.1f%%  totalTicks=%.0f (≈%.0f ticks/s/core)", 100*du/t, 100*ds/t, 100*di/t, 100*dn/t, t, t/secs/18))
    let sumPer = zip(a, b).reduce(0.0) { acc, pq in acc + Double(pq.1[0] &- pq.0[0]) + Double(pq.1[1] &- pq.0[1]) + Double(pq.1[3] &- pq.0[3]) }
    let totPer = zip(a, b).reduce(0.0) { acc, pq in acc + (0..<4).reduce(0.0) { $0 + Double(pq.1[$1] &- pq.0[$1]) } }
    print(String(format: "  mean of per-core busy = %.1f%%", 100*sumPer/totPer))
}
measure("IDLE (no load):")
func spin(_ n: Int, qos: QualityOfService) {
    stopFlag.store(false, ordering: .sequentiallyConsistent)
    for _ in 0..<n { let t = Thread { var x = 1.0; while !stopFlag.load(ordering: .relaxed) { for _ in 0..<1000 { x = x * 1.0000001 + 0.5 } }; sink += x }; t.qualityOfService = qos; t.start() }
    Thread.sleep(forTimeInterval: 0.3)
}
spin(6, qos: .background); measure("LOAD: 6 threads QoS .background:"); stopFlag.store(true, ordering: .sequentiallyConsistent); Thread.sleep(forTimeInterval: 0.3)
spin(6, qos: .userInteractive); measure("LOAD: 6 threads QoS .userInteractive:"); stopFlag.store(true, ordering: .sequentiallyConsistent); Thread.sleep(forTimeInterval: 0.3)
spin(18, qos: .userInitiated); measure("LOAD: 18 threads QoS .userInitiated:"); stopFlag.store(true, ordering: .sequentiallyConsistent)
