// Probe: rusage_info_v6 per-core-type split for own process: ri_user_ptime/ri_system_ptime (perflevel0 = Super on this Mac),
// ri_pcycles/ri_pinstructions, ri_energy_nj/ri_penergy_nj, under QoS userInteractive vs background load.
import Foundation
import Darwin
import Synchronization
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); let k = Double(tb.numer) / Double(tb.denom) / 1e9
func ru() -> rusage_info_v6 { var r = rusage_info_v6(); _ = withUnsafeMutablePointer(to: &r) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }; return r }
let stop = Atomic<Bool>(false); nonisolated(unsafe) var sink = 0.0
func run(_ qos: QualityOfService, _ n: Int) {
    stop.store(false, ordering: .relaxed)
    let a = ru(); let t0 = Date()
    for _ in 0..<n { let t = Thread { var x = 1.0; while !stop.load(ordering: .relaxed) { for _ in 0..<1000 { x = x * 1.0000001 + 0.5 } }; sink += x }; t.qualityOfService = qos; t.start() }
    Thread.sleep(forTimeInterval: 1.0); stop.store(true, ordering: .relaxed); Thread.sleep(forTimeInterval: 0.1)
    let b = ru(); let dt = Date().timeIntervalSince(t0)
    let tot = Double((b.ri_user_time - a.ri_user_time) + (b.ri_system_time - a.ri_system_time)) * k
    let p = Double((b.ri_user_ptime - a.ri_user_ptime) + (b.ri_system_ptime - a.ri_system_ptime)) * k
    let cyc = Double(b.ri_cycles - a.ri_cycles), pc = Double(b.ri_pcycles - a.ri_pcycles)
    let e = Double(b.ri_energy_nj - a.ri_energy_nj) / 1e9, pe = Double(b.ri_penergy_nj - a.ri_penergy_nj) / 1e9
    print(String(format: "%@ x%d: cpu=%.2fs ptime(Super)=%.2fs (%.0f%%) cycles=%.2e pcycles=%.2e => %.0f MHz eff; instr=%.2e IPC=%.2f; energy=%.2fJ (%.2fW) penergy=%.2fJ",
                 qos == .userInteractive ? "userInteractive" : (qos == .background ? "background" : "userInitiated"), n, tot, p, tot > 0 ? 100 * p / tot : 0, cyc, pc, tot > 0 ? cyc / tot / 1e6 : 0,
                 Double(b.ri_instructions - a.ri_instructions), cyc > 0 ? Double(b.ri_instructions - a.ri_instructions) / cyc : 0, e, e / dt, pe))
}
run(.userInteractive, 6); run(.background, 6); run(.userInitiated, 18)
