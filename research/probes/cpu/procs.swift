// Probe: top processes by CPU natively via libproc (no /bin/ps): proc_listallpids, proc_pidinfo(PROC_PIDTASKINFO),
// proc_pid_rusage(RUSAGE_INFO_V6), PROC_PIDTBSDSHORTINFO, proc_name/proc_pidpath; which calls fail for root/other-uid processes;
// unit check of pti_total_user vs ri_user_time; names/icons via NSRunningApplication / NSWorkspace.
import Foundation
import AppKit
import Darwin

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
let machToNs = Double(tb.numer) / Double(tb.denom)
let myUid = getuid()
print("uid=\(myUid) timebase=\(tb.numer)/\(tb.denom)")

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return Array(buf.prefix(Int(got))).filter { $0 > 0 }
}
struct Snap { var taskOK = false; var rusOK = false; var ptiUser: UInt64 = 0; var ptiSys: UInt64 = 0; var csw: Int32 = 0; var riUser: UInt64 = 0; var riSys: UInt64 = 0; var riPUser: UInt64 = 0; var riPSys: UInt64 = 0; var energy: UInt64 = 0; var penergy: UInt64 = 0; var instr: UInt64 = 0; var cycles: UInt64 = 0; var uid: uid_t = 0; var uidOK = false; var threads: Int32 = 0; var taskErrno: Int32 = 0; var rusErrno: Int32 = 0 }
func snap(_ pid: pid_t) -> Snap {
    var s = Snap()
    var ti = proc_taskinfo()
    let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
    if r == Int32(MemoryLayout<proc_taskinfo>.size) { s.taskOK = true; s.ptiUser = ti.pti_total_user; s.ptiSys = ti.pti_total_system; s.csw = ti.pti_csw; s.threads = ti.pti_threadnum } else { s.taskErrno = errno }
    var ru = rusage_info_v6()
    let rr = withUnsafeMutablePointer(to: &ru) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) } }
    if rr == 0 { s.rusOK = true; s.riUser = ru.ri_user_time; s.riSys = ru.ri_system_time; s.riPUser = ru.ri_user_ptime; s.riPSys = ru.ri_system_ptime; s.energy = ru.ri_energy_nj; s.penergy = ru.ri_penergy_nj; s.instr = ru.ri_instructions; s.cycles = ru.ri_cycles } else { s.rusErrno = errno }
    var bi = proc_bsdshortinfo()
    if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdshortinfo>.size)) == Int32(MemoryLayout<proc_bsdshortinfo>.size) { s.uid = bi.pbsi_uid; s.uidOK = true }
    return s
}
func name(_ pid: pid_t) -> (String, String) {
    var nb = [CChar](repeating: 0, count: 256); proc_name(pid, &nb, 256)
    var pb = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4); let pl = proc_pidpath(pid, &pb, UInt32(pb.count))
    return (String(cString: nb), pl > 0 ? String(cString: pb) : "<proc_pidpath failed errno=\(errno)>")
}

// ---- unit check on self: burn ~0.5s CPU
let t0 = snap(getpid()); var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
var x = 1.0; let end = Date().addingTimeInterval(0.5); while Date() < end { for _ in 0..<10000 { x = x * 1.0000001 + 0.5 } }
let t1 = snap(getpid()); var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
let gr = Double(ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) + Double(ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e6
print(String(format: "UNIT CHECK self: getrusage user=%.3fs | pti_total_user delta raw=%llu (as ns=%.3fs, as mach=%.3fs) | ri_user_time delta raw=%llu (as ns=%.3fs, as mach=%.3fs) | x=%.1f",
    gr, t1.ptiUser - t0.ptiUser, Double(t1.ptiUser - t0.ptiUser)/1e9, Double(t1.ptiUser - t0.ptiUser)*machToNs/1e9, t1.riUser - t0.riUser, Double(t1.riUser - t0.riUser)/1e9, Double(t1.riUser - t0.riUser)*machToNs/1e9, x.truncatingRemainder(dividingBy: 10)))

// ---- sample all processes twice
let pids = allPids()
var a: [pid_t: Snap] = [:]; for p in pids { a[p] = snap(p) }
let ta = Date()
Thread.sleep(forTimeInterval: 1.0)
var b: [pid_t: Snap] = [:]; for p in allPids() { b[p] = snap(p) }
let dt = Date().timeIntervalSince(ta)

var stats: [String: Int] = [:]
func bump(_ k: String) { stats[k, default: 0] += 1 }
for (p, s) in b {
    let own = s.uidOK && s.uid == myUid
    let key = !s.uidOK ? "uid?" : (s.uid == 0 ? "root" : (own ? "own" : "other-uid"))
    bump("\(key).total"); if s.taskOK { bump("\(key).PROC_PIDTASKINFO ok") } else { bump("\(key).PROC_PIDTASKINFO fail errno=\(s.taskErrno)") }
    if s.rusOK { bump("\(key).proc_pid_rusage ok") } else { bump("\(key).proc_pid_rusage fail errno=\(s.rusErrno)") }
    _ = p
}
print("\nprocesses: \(b.count), sample dt=\(String(format: "%.3f", dt))s")
for k in stats.keys.sorted() { print("  \(k): \(stats[k]!)") }

struct Row { let pid: pid_t; let cpu: Double; let src: String; let pShare: Double?; let watts: Double?; let uid: uid_t }
var rows: [Row] = []
for (p, sb) in b {
    guard let sa = a[p] else { continue }
    if sb.taskOK && sa.taskOK {
        let d = Double((sb.ptiUser &- sa.ptiUser) &+ (sb.ptiSys &- sa.ptiSys)) * machToNs
        var pShare: Double? = nil; var w: Double? = nil
        if sb.rusOK && sa.rusOK {
            let tot = Double((sb.riUser &- sa.riUser) &+ (sb.riSys &- sa.riSys)); let pt = Double((sb.riPUser &- sa.riPUser) &+ (sb.riPSys &- sa.riPSys))
            if tot > 0 { pShare = pt / tot }
            w = Double(sb.energy &- sa.energy) / 1e9 / dt
        }
        rows.append(Row(pid: p, cpu: 100 * d / 1e9 / dt, src: "taskinfo", pShare: pShare, watts: w, uid: sb.uid))
    } else if sb.rusOK && sa.rusOK {
        let d = Double((sb.riUser &- sa.riUser) &+ (sb.riSys &- sa.riSys)) * machToNs
        rows.append(Row(pid: p, cpu: 100 * d / 1e9 / dt, src: "rusage", pShare: nil, watts: Double(sb.energy &- sa.energy) / 1e9 / dt, uid: sb.uid))
    }
}
rows.sort { $0.cpu > $1.cpu }
print("\nTOP 15 by CPU% (libproc deltas; pti_* treated as mach ticks x \(tb.numer)/\(tb.denom)); pShare = fraction of CPU time on perflevel0 (Super) cores from ri_*_ptime; W = ri_energy_nj delta")
for r in rows.prefix(15) {
    let (n, path) = name(r.pid)
    let app = NSRunningApplication(processIdentifier: r.pid)
    let icon = app?.icon != nil ? "app-icon" : (path.hasPrefix("/") ? "file-icon(NSWorkspace)" : "none")
    print(String(format: "  pid=%6d uid=%3d cpu=%6.1f%% pShare=%@ W=%@ name=%@ localized=%@ icon=%@ path=%@", r.pid, r.uid, r.cpu,
                 r.pShare.map { String(format: "%.2f", $0) } ?? "n/a", r.watts.map { String(format: "%.3f", $0) } ?? "n/a", n, app?.localizedName ?? "-", icon, path))
}
// Show a few root processes explicitly to document which fields fail
print("\nSample root-owned processes (field availability):")
for (p, s) in b.filter({ $0.value.uid == 0 }).sorted(by: { $0.key < $1.key }).prefix(6) {
    let (n, path) = name(p)
    print("  pid=\(p) name=\(n) taskinfo=\(s.taskOK ? "ok" : "FAIL(errno \(s.taskErrno))") rusage=\(s.rusOK ? "ok" : "FAIL(errno \(s.rusErrno))") path=\(path)")
}
