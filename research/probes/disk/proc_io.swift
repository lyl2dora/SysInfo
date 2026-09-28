// Per-process disk I/O via proc_pid_rusage (ri_diskio_bytesread/written) over all pids, as the unprivileged user
import Foundation
import Darwin

func pids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = buf.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
    return Array(buf.prefix(Int(got)))
}
func name(_ pid: pid_t) -> String { var b = [CChar](repeating: 0, count: 256); proc_name(pid, &b, 256); return String(cString: b) }
func uid(_ pid: pid_t) -> uid_t? { var i = proc_bsdshortinfo(); return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &i, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 ? i.pbsi_uid : nil }

func sample() -> (ok: [pid_t: (UInt64, UInt64)], errs: [Int32: Int], failedExamples: [String]) {
    var ok: [pid_t: (UInt64, UInt64)] = [:]; var errs: [Int32: Int] = [:]; var ex: [String] = []
    for p in pids() {
        var u = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &u) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V6, $0) } }
        if r == 0 { ok[p] = (u.ri_diskio_bytesread, u.ri_diskio_byteswritten) }
        else { errs[errno, default: 0] += 1; if ex.count < 8 { ex.append("\(p):\(name(p)) uid=\(uid(p).map(String.init) ?? "?") errno=\(errno)") } }
    }
    return (ok, errs, ex)
}

let t0 = Date()
let a = sample()
let cost = Date().timeIntervalSince(t0) * 1000
let all = pids()
let rootOK = a.ok.keys.filter { uid($0) == 0 }.count
let rootTotal = all.filter { uid($0) == 0 }.count
print(String(format: "pids=%d rusage ok=%d failed=%@ (sample cost %.1f ms, no /bin/ps spawn)", all.count, a.ok.count, a.errs.description, cost))
print("root-owned pids: \(rootTotal), rusage ok for \(rootOK)")
print("failed examples: \(a.failedExamples)")
for p in [0, 1] as [pid_t] { if let v = a.ok[p] { print("pid \(p) \(name(p)): read=\(v.0) written=\(v.1)") } else { print("pid \(p) \(name(p)): not readable") } }
Thread.sleep(forTimeInterval: 3)
let b = sample()
var deltas: [(pid_t, UInt64, UInt64)] = []
for (p, v) in b.ok { if let o = a.ok[p] { let dr = v.0 &- o.0, dw = v.1 &- o.1; if dr > 0 || dw > 0 { deltas.append((p, dr, dw)) } } }
deltas.sort { max($0.1, $0.2) > max($1.1, $1.2) }
print("top processes by disk I/O over 3 s:")
for d in deltas.prefix(12) { print("  pid=\(d.0) \(name(d.0)) uid=\(uid(d.0).map(String.init) ?? "?") read=\(d.1)B write=\(d.2)B") }
print("processes with nonzero I/O: \(deltas.count)")
