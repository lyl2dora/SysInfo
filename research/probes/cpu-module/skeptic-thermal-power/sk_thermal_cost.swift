// sk_thermal_cost.swift — 复核 ProcessInfo.thermalState 读取开销与当前值；同时读 notify thermalpressurelevel。只读。
import Foundation
import Darwin
import notify
func tcpu() -> Double { var ts = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return Double(ts.tv_sec) * 1e6 + Double(ts.tv_nsec) / 1e3 }
var per: [Double] = []
var s = 0
for _ in 0..<40 {
    let a = tcpu()
    for _ in 0..<10000 { s &+= ProcessInfo.processInfo.thermalState.rawValue }
    per.append((tcpu() - a) / 10000)
}
per.sort()
var tok: Int32 = 0; var st: UInt64 = 0
notify_register_check("com.apple.system.thermalpressurelevel", &tok); notify_get_state(tok, &st)
var bogus: Int32 = 0; let r = notify_register_check("com.example.definitely.not.a.real.name", &bogus); var bs: UInt64 = 99; notify_get_state(bogus, &bs)
print(String(format: "thermalState 读取：中位 %.3f µs（p10 %.3f p90 %.3f）；当前 thermalState=%d；thermalpressurelevel=%llu；不存在的通知名 register 返回 %d、state=%llu", per[20], per[4], per[36], ProcessInfo.processInfo.thermalState.rawValue, st, r, bs))
_ = s
