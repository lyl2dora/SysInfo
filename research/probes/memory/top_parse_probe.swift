// top_parse_probe.swift - replicate Stats ProcessReader (Modules/RAM/readers.swift:124-166, 228-276) on macOS 27 top output,
// compare parsed bytes with native proc_pid_rusage ri_phys_footprint, and measure top's CPU cost.
import Foundation
import Darwin

func runTop(_ n: Int) -> String {
    let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    t.arguments = ["-l", "1", "-o", "mem", "-n", "\(n)", "-stats", "pid,command,mem"]
    let p = Pipe(); t.standardOutput = p; t.standardError = Pipe()
    try! t.run(); let d = p.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}
// verbatim logic of Stats parseProcess (minus NSRunningApplication name lookup)
func statsParse(_ raw: String) -> (Int, String, Double) {
    var str = raw.trimmingCharacters(in: .whitespaces)
    let pidString = str.range(of: "^\\d+", options: .regularExpression).map { String(str[$0]) } ?? ""
    if let range = str.range(of: pidString) { str = str.replacingCharacters(in: range, with: "") }
    var arr = str.split(separator: " ")
    if arr.first == "*" { arr.removeFirst() }
    var usageString = str.suffix(6)
    if let last = arr.last { usageString = last; arr.removeLast() }
    let command = arr.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    let pid = Int(pidString) ?? 0
    var usage = Double(usageString.filter("01234567890.".contains)) ?? 0
    if usageString.last == "G" { usage *= 1024 }
    else if usageString.last == "K" { usage /= 1024 }
    else if usageString.last == "M" && usageString.count == 5 { usage /= 1024; usage *= 1000 }
    return (pid, command, usage * Double(1000 * 1000))
}
func footprint(_ pid: Int) -> UInt64? {
    var ru = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &ru) { $0.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { proc_pid_rusage(Int32(pid), RUSAGE_INFO_V6, $0) } }
    return rc == 0 ? ru.ri_phys_footprint : nil
}
let out = runTop(15)
let regex = try! NSRegularExpression(pattern: "^\\d+\\** +.* +\\d+[A-Z]*\\+?\\-? *$")
var matched = 0
print(String(format: "%-7@ %-20@ %-8@ %14@ %14@ %14@ %8@", "pid", "command", "topMEM", "statsBytes", "statsShown", "nativeFoot", "err%"))
let bcf = ByteCountFormatter(); bcf.countStyle = .memory
out.enumerateLines { line, _ in
    guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return }
    matched += 1
    let (pid, cmd, bytes) = statsParse(line)
    let topMem = line.split(separator: " ").last.map(String.init) ?? "?"
    let nf = footprint(pid)
    let err = nf.map { String(format: "%+.1f", (bytes - Double($0)) / Double($0) * 100) } ?? "n/a(EPERM)"
    print(String(format: "%-7d %-20@ %-8@ %14.0f %14@ %14@ %8@", pid, String(cmd.prefix(20)), topMem, bytes, bcf.string(fromByteCount: Int64(bytes)), nf.map { bcf.string(fromByteCount: Int64($0)) } ?? "EPERM", err))
}
print("regex matched \(matched) process lines")
// cost of top -l 1 (children rusage)
var before = rusage(); getrusage(RUSAGE_CHILDREN, &before)
let t0 = Date(); for _ in 0..<5 { _ = runTop(8) }; let wall = Date().timeIntervalSince(t0) / 5
var after = rusage(); getrusage(RUSAGE_CHILDREN, &after)
func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
let cpu = (sec(after.ru_utime) + sec(after.ru_stime) - sec(before.ru_utime) - sec(before.ru_stime)) / 5
print(String(format: "top -l 1 cost: wall %.0f ms, CPU %.0f ms per invocation (Stats default: every 1 s => ~%.0f%% of one core)", wall*1000, cpu*1000, cpu*100))
