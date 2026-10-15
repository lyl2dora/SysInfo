// names.swift - Top N 的呈现粒度、进程名与图标来源、coalition「代表成员」的选取，以及各查找的开销。只读。
// 用法：names [窗口秒=2] [显示前 N=12]
// 1) 全部 live coalition 的成员构成统计（单成员 / 多成员、含 .app 的、含多个 .app 的、含 root 成员的……）
// 2) 名称/图标来源逐项计时：SHORTBSDINFO comm（16 字节截断）、proc_pidpath、kinfo_proc、NSRunningApplication、
//    Bundle(url:) 本地化名、NSWorkspace.icon(forFile:)（首次/缓存）、responsibility_get_pid_responsible_for_pid
// 3) 代表成员启发式：NSRunningApplication(.regular 优先) → 路径中最外层 .app → 最早启动的成员
// 4) 2 s 窗口的 Top N：按 coalition 显示，并列出成员拆分（同 uid → libproc 精确；只剩一个不可读成员 → 残差；否则「其余」）
// build: xcrun swiftc -O -o names names.swift
import AppKit
import Darwin

let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
typealias CruFn = @convention(c) (UInt64, UnsafeMutableRawPointer, Int) -> Int32
typealias PlFn = @convention(c) (UInt64, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>) -> Int32
typealias LcFn = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
typealias RespFn = @convention(c) (pid_t) -> pid_t
let cru = unsafeBitCast(dlsym(RTLD_DEFAULT, "coalition_info_resource_usage")!, to: CruFn.self)
let pl = unsafeBitCast(dlsym(RTLD_DEFAULT, "coalition_info_pid_list")!, to: PlFn.self)
let lc = unsafeBitCast(dlsym(RTLD_DEFAULT, "proc_listcoalitions")!, to: LcFn.self)
let resp = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: RespFn.self) }

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); let tick2s = Double(tb.numer) / Double(tb.denom) / 1e9
func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
func sysctlStr(_ n: String) -> String { var s = 0; sysctlbyname(n, nil, &s, nil, 0); var b = [CChar](repeating: 0, count: max(s, 1)); sysctlbyname(n, &b, &s, nil, 0); return String(cString: b) }

struct Coal { var cid: UInt64; var tasks: UInt32; var slots: [UInt64]; var pids: [pid_t] }
func listCoalitions() -> [Coal] {
    let bytes = lc(2, 0, nil, 0); let cap = Int(bytes) + 64 * 16
    let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 8); defer { buf.deallocate() }
    let n = Int(lc(2, 0, buf, Int32(cap))) / 16
    var out: [Coal] = []
    for i in 0..<n {
        let cid = buf.load(fromByteOffset: i * 16, as: UInt64.self), tasks = buf.load(fromByteOffset: i * 16 + 12, as: UInt32.self)
        if tasks == 0 { continue }
        var s = [UInt64](repeating: 0, count: 50); _ = s.withUnsafeMutableBytes { cru(cid, $0.baseAddress!, 400) }
        var p = [pid_t](repeating: 0, count: Int(tasks) + 16); var sz = p.count * 4
        let rc = p.withUnsafeMutableBytes { pl(cid, $0.baseAddress!, &sz) }
        out.append(Coal(cid: cid, tasks: tasks, slots: s, pids: rc == 0 ? Array(p.prefix(sz / 4)) : []))
    }
    return out
}
func cpuTicks(_ s: [UInt64]) -> UInt64 { (24...30).reduce(0) { $0 + s[$1] } }

struct PInfo { var pid: pid_t; var uid: uid_t; var comm: String; var path: String; var start: Double; var ppid: pid_t }
func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? { var si = proc_bsdshortinfo(); let n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, Int32(MemoryLayout<proc_bsdshortinfo>.size)); return n == MemoryLayout<proc_bsdshortinfo>.size ? si : nil }
func pidPath(_ pid: pid_t) -> String { var b = [CChar](repeating: 0, count: 4096); return proc_pidpath(pid, &b, 4096) > 0 ? String(cString: b) : "" }
func kinfo(_ pid: pid_t) -> kinfo_proc? { var k = kinfo_proc(); var sz = MemoryLayout<kinfo_proc>.size; var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]; return sysctl(&mib, 4, &k, &sz, nil, 0) == 0 && sz > 0 ? k : nil }
func info(_ pid: pid_t) -> PInfo {
    let si = shortInfo(pid); let k = kinfo(pid)
    let comm = si.map { withUnsafeBytes(of: $0.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } } ?? "?"
    let st = k.map { Double($0.kp_proc.p_un.__p_starttime.tv_sec) + Double($0.kp_proc.p_un.__p_starttime.tv_usec) / 1e6 } ?? 0
    return PInfo(pid: pid, uid: si?.pbsi_uid ?? (k?.kp_eproc.e_ucred.cr_uid ?? 99999), comm: comm, path: pidPath(pid), start: st, ppid: pid_t(si?.pbsi_ppid ?? 0))
}
func rusage(_ pid: pid_t) -> rusage_info_v6? {
    var r = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &r) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) } }
    return rc == 0 ? r : nil
}
/// 路径中最外层的 .app（XPC 服务、helper app、嵌套 app 都归到最外层）
func outermostApp(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
    return String(path[..<r.lowerBound]) + ".app"
}
func bundleName(_ appPath: String) -> String? {
    guard let b = Bundle(path: appPath) else { return nil }
    return (b.localizedInfoDictionary?["CFBundleDisplayName"] as? String) ?? (b.localizedInfoDictionary?["CFBundleName"] as? String)
        ?? (b.infoDictionary?["CFBundleDisplayName"] as? String) ?? (b.infoDictionary?["CFBundleName"] as? String)
}

let window = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 2 : 2
let topN = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 12 : 12
let me = getuid()
print("# machine: \(sysctlStr("hw.model")) / \(sysctlStr("machdep.cpu.brand_string")) / build \(sysctlStr("kern.osversion"))  (run from: ppid chain of pid \(getpid()))")

// ---------- 1) 构成统计
var t0 = threadCPU()
let coals = listCoalitions()
var infos: [pid_t: PInfo] = [:]
for c in coals { for p in c.pids where infos[p] == nil { infos[p] = info(p) } }
let tEnum = threadCPU() - t0
var single = 0, multi = 0, withApp = 0, multiApp = 0, withRootMember = 0, mixedUid = 0
var sizeHist: [Int: Int] = [:]
for c in coals {
    let n = c.pids.count; sizeHist[min(n, 10), default: 0] += 1
    if n == 1 { single += 1 } else if n > 1 { multi += 1 }
    let apps = Set(c.pids.compactMap { infos[$0].flatMap { outermostApp($0.path) } }); if !apps.isEmpty { withApp += 1 }; if apps.count > 1 { multiApp += 1 }
    let uids = Set(c.pids.compactMap { infos[$0]?.uid }); if uids.contains(0) && n > 1 { withRootMember += 1 }; if uids.count > 1 { mixedUid += 1 }
}
print("1) live coalitions \(coals.count), pids in them \(infos.count): single-member \(single), multi-member \(multi); size histogram (10 = 10+): \(sizeHist.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
print("   coalitions containing an .app path \(withApp), containing >1 distinct outermost .app \(multiApp), multi-member with a root member \(withRootMember), mixed-uid \(mixedUid); enumeration+per-pid info took \(String(format: "%.2f", tEnum)) ms thread CPU")

// ---------- 2) 查找开销（逐项，全体 pid）
let allPids = Array(infos.keys)
func timeIt(_ label: String, _ body: () -> Int) { let a = threadCPU(); let ok = body(); let d = threadCPU() - a
    print(String(format: "   %-62@ %8.3f ms total, %7.2f µs/pid, ok %d/%d", label as NSString, d, d * 1000 / Double(allPids.count), ok, allPids.count)) }
print("2) lookup costs over \(allPids.count) pids (thread CPU):")
timeIt("SHORTBSDINFO (comm is 16-byte truncated)") { allPids.filter { shortInfo($0) != nil }.count }
timeIt("proc_pidpath") { allPids.filter { !pidPath($0).isEmpty }.count }
timeIt("sysctl KERN_PROC_PID (start time, uid)") { allPids.filter { kinfo($0) != nil }.count }
timeIt("NSRunningApplication(processIdentifier:) [first call]") { allPids.filter { NSRunningApplication(processIdentifier: $0) != nil }.count }
timeIt("NSRunningApplication(processIdentifier:) [again]") { allPids.filter { NSRunningApplication(processIdentifier: $0) != nil }.count }
if let resp { timeIt("responsibility_get_pid_responsible_for_pid (>0)") { allPids.filter { resp($0) > 0 }.count }
    timeIt("  ... responsible pid != self (grouping signal)") { allPids.filter { let r = resp($0); return r > 0 && r != $0 }.count } }
let appPaths = Array(Set(allPids.compactMap { infos[$0].flatMap { outermostApp($0.path) } }))
do { let a = threadCPU(); let ok = appPaths.filter { bundleName($0) != nil }.count; let d = threadCPU() - a
    print(String(format: "   %-62@ %8.3f ms total, %7.2f µs/app, ok %d/%d", "Bundle(path:) + localized CFBundleDisplayName/Name (distinct .app)" as NSString, d, d * 1000 / Double(max(appPaths.count, 1)), ok, appPaths.count)) }
do { let a = threadCPU(); var sz = 0; for p in appPaths { sz += NSWorkspace.shared.icon(forFile: p).representations.count }; let d = threadCPU() - a
    let b = threadCPU(); for p in appPaths { _ = NSWorkspace.shared.icon(forFile: p) }; let d2 = threadCPU() - b
    // 实际画出来才会解码位图
    let c = threadCPU(); for p in appPaths.prefix(20) { let img = NSWorkspace.shared.icon(forFile: p); img.size = NSSize(width: 16, height: 16); _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil) }; let d3 = threadCPU() - c
    print(String(format: "   NSWorkspace.icon(forFile:) %d apps: first %.2f ms (%.0f µs/app), again %.2f ms; render 16pt CGImage for 20: %.2f ms (%.0f µs each)", appPaths.count, d, d * 1000 / Double(max(appPaths.count, 1)), d2, d3, d3 * 1000 / 20)) }
let nra = allPids.compactMap { NSRunningApplication(processIdentifier: $0) }
let pol = Dictionary(grouping: nra, by: { $0.activationPolicy.rawValue }).mapValues { $0.count }
print("   NSRunningApplication found \(nra.count) (activationPolicy regular=\(pol[0] ?? 0) accessory=\(pol[1] ?? 0) prohibited=\(pol[2] ?? 0)); NSWorkspace.runningApplications count \(NSWorkspace.shared.runningApplications.count)")

// ---------- 3) 代表成员
struct Rep { var name: String; var how: String; var icon: String; var leader: pid_t }
var nameCache: [String: String] = [:]
func representative(_ c: Coal) -> Rep {
    let ms = c.pids.compactMap { infos[$0] }
    if ms.isEmpty { return Rep(name: "(no members)", how: "-", icon: "-", leader: -1) }
    // a) LaunchServices 登记的前台 app
    let apps = ms.compactMap { m -> (PInfo, NSRunningApplication)? in NSRunningApplication(processIdentifier: m.pid).map { (m, $0) } }
    if let best = apps.sorted(by: { ($0.1.activationPolicy.rawValue, $0.0.start) < ($1.1.activationPolicy.rawValue, $1.0.start) }).first {
        return Rep(name: best.1.localizedName ?? best.0.comm, how: "NSRunningApplication(\(best.1.activationPolicy == .regular ? "regular" : best.1.activationPolicy == .accessory ? "accessory" : "prohibited"))", icon: "NSRunningApplication.icon", leader: best.0.pid) }
    // b) 路径里有 .app
    if let m = ms.filter({ outermostApp($0.path) != nil }).min(by: { $0.start < $1.start }), let app = outermostApp(m.path) {
        let n = nameCache[app] ?? bundleName(app) ?? (app as NSString).lastPathComponent; nameCache[app] = n
        return Rep(name: n, how: "outermost .app in path", icon: "NSWorkspace.icon(forFile: .app)", leader: m.pid) }
    // c) 最早启动的成员
    let m = ms.min(by: { $0.start < $1.start })!
    let n = m.pid == 0 ? "kernel_task" : (m.path.isEmpty ? m.comm : (m.path as NSString).lastPathComponent)
    return Rep(name: n, how: "earliest-start member", icon: "generic executable icon", leader: m.pid)
}
t0 = threadCPU(); let reps = coals.map(representative); let tRep = threadCPU() - t0
let howHist = Dictionary(grouping: reps, by: { $0.how.hasPrefix("NSRunning") ? "NSRunningApplication" : $0.how }).mapValues { $0.count }
print("3) representative member for \(coals.count) coalitions in \(String(format: "%.1f", tRep)) ms: \(howHist.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
// 显示一批多成员的例子
print("   multi-member examples (members as comm[uid]):")
for (c, r) in zip(coals, reps).filter({ $0.0.pids.count > 1 }).sorted(by: { $0.0.pids.count > $1.0.pids.count }).prefix(14) {
    let mem = c.pids.prefix(8).compactMap { infos[$0] }.map { "\($0.pid == 0 ? "kernel_task" : ($0.path.isEmpty ? $0.comm : ($0.path as NSString).lastPathComponent))[\($0.uid)]" }.joined(separator: ", ")
    print("     cid \(c.cid) \(c.pids.count) members -> \"\(r.name)\" via \(r.how): \(mem)\(c.pids.count > 8 ? ", …" : "")")
}
// comm 截断的例子
let trunc = infos.values.filter { !$0.path.isEmpty && ($0.path as NSString).lastPathComponent.count > 15 && ($0.path as NSString).lastPathComponent.hasPrefix($0.comm) && $0.comm.count >= 15 }
print("   comm truncated to 15-16 chars for \(trunc.count) pids, e.g. \(trunc.prefix(3).map { "\"\($0.comm)\" -> \"\(($0.path as NSString).lastPathComponent)\"" }.joined(separator: "; "))")

// ---------- 4) 2 s 窗口的 Top N
let a = listCoalitions(); var ra: [pid_t: rusage_info_v6] = [:]; for c in a { for p in c.pids { if let r = rusage(p) { ra[p] = r } } }
let ta = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
Thread.sleep(forTimeInterval: window)
let b = listCoalitions(); let tbb = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); var rb: [pid_t: rusage_info_v6] = [:]
for c in b { for p in c.pids { if infos[p] == nil { infos[p] = info(p) }; if let r = rusage(p) { rb[p] = r } } }
let dt = Double(tbb - ta) / 1e9
let prev = Dictionary(uniqueKeysWithValues: a.map { ($0.cid, $0) })
func pcpu(_ r1: rusage_info_v6, _ r0: rusage_info_v6) -> Double { Double((r1.ri_user_time &+ r1.ri_system_time) &- (r0.ri_user_time &+ r0.ri_system_time)) * tick2s / dt * 100 }
var rows: [(Coal, Double, Double)] = []
for c in b { guard let p = prev[c.cid] else { continue }; let cpu = Double(cpuTicks(c.slots) &- cpuTicks(p.slots)) * tick2s / dt * 100; let w = Double(c.slots[11] &- p.slots[11]) / 1e9 / dt; rows.append((c, cpu, w)) }
rows.sort { $0.1 > $1.1 }
print(String(format: "4) Top %d coalitions by CP%% over %.2f s window (100%% = one core); members: exact(libproc) / residual / rest", topN, dt))
for (c, cpu, w) in rows.prefix(topN) {
    let r = representative(c)
    print(String(format: "   %6.1f%%  %6.3f W  %-34@ [%d member%@, cid %llu, via %@]", cpu, w, r.name as NSString, c.pids.count, c.pids.count == 1 ? "" : "s", c.cid, r.how as NSString))
    if c.pids.count > 1 {
        var known = 0.0; var unread: [pid_t] = []; var parts: [(String, Double)] = []
        for p in c.pids { if let r1 = rb[p], let r0 = ra[p] { let v = pcpu(r1, r0); known += v; parts.append(((infos[p]?.path as NSString?)?.lastPathComponent ?? infos[p]?.comm ?? "?", v)) } else { unread.append(p) } }
        parts.sort { $0.1 > $1.1 }
        var line = parts.prefix(4).map { String(format: "%@ %.1f%%", $0.0 as NSString, $0.1) }.joined(separator: ", ")
        let rest = cpu - known
        let started = c.slots[0] &- (prev[c.cid]?.slots[0] ?? c.slots[0]), exited = c.slots[1] &- (prev[c.cid]?.slots[1] ?? c.slots[1])
        let churn = started > 0 || exited > 0
        if churn { line += String(format: "%@[window churn: +%llu started, +%llu exited -> residual not attributable] rest %.1f%%", line.isEmpty ? "" : "; ", started, exited, rest) }
        else if unread.count == 1, let u = infos[unread[0]] { line += String(format: "%@%@[uid %d, residual] %.1f%%", line.isEmpty ? "" : ", ", (u.path.isEmpty ? u.comm : (u.path as NSString).lastPathComponent) as NSString, u.uid, rest) }
        else if unread.count > 1 { line += String(format: "%@%d unreadable members together %.1f%%", line.isEmpty ? "" : ", ", unread.count, rest) }
        else if abs(rest) >= 0.05 { line += String(format: "; exited/new tasks in window %.1f%%", rest) }
        print("            └ \(line)")
    }
}
