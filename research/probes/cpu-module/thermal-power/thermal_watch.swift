// thermal_watch.swift — 热状态：ProcessInfo.thermalState（公开，4 档）与 notify "com.apple.system.thermalpressurelevel"（OSThermalPressureLevel）。
// 打印初值；订阅两种变化通知 N 秒并记录变化；测量单次读取的线程 CPU 开销（各 2000 次取中位数）。只读。用法：thermal_watch [秒数]
import Foundation
import Darwin
import notify
func tcpu() -> Double { var ts = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return Double(ts.tv_sec) * 1e3 + Double(ts.tv_nsec) / 1e6 }
let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 5
let pi = ProcessInfo.processInfo
let tnames = ["nominal", "fair", "serious", "critical"]
let name = "com.apple.system.thermalpressurelevel"
var tok: Int32 = 0
precondition(notify_register_check(name, &tok) == NOTIFY_STATUS_OK)
func level() -> UInt64 { var s: UInt64 = 0; notify_get_state(tok, &s); return s }
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
print("\(fmt.string(from: Date())) init thermalState=\(pi.thermalState.rawValue)(\(tnames[pi.thermalState.rawValue])) pressureLevel=\(level()) lowPower=\(pi.isLowPowerModeEnabled)")
// 其它可能相关的 notify 名
for k in ["com.apple.system.thermalpressurelevel.cold", "com.apple.system.powermanagement.cpupowerstatus", "com.apple.system.powermanagement.thermallevel", "com.apple.system.thermalstate"] {
    var t: Int32 = 0; var st: UInt64 = 0; let a = notify_register_check(k, &t); let b = notify_get_state(t, &st); print("  notify \(k): reg=\(a) get=\(b) state=\(st)")
}
// 开销
func median(_ f: () -> Void) -> Double { var a: [Double] = []; for _ in 0..<2000 { let c = tcpu(); f(); a.append(tcpu() - c) }; a.sort(); return a[1000] * 1000 }
var sink = 0
print(String(format: "cost: ProcessInfo.thermalState median %.2f µs; notify_get_state median %.2f µs", median { sink &+= pi.thermalState.rawValue }, median { sink &+= Int(level()) }))
var tok2: Int32 = 0
notify_register_dispatch(name, &tok2, DispatchQueue.main) { _ in print("\(fmt.string(from: Date())) notify pressure changed -> \(level()) thermalState=\(pi.thermalState.rawValue)") }
let obs = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in print("\(fmt.string(from: Date())) thermalStateDidChange -> \(pi.thermalState.rawValue) level=\(level())") }
RunLoop.main.run(until: Date(timeIntervalSinceNow: secs))
print("\(fmt.string(from: Date())) end thermalState=\(pi.thermalState.rawValue) pressureLevel=\(level()) sink=\(sink & 1)")
_ = obs
