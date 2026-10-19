// 电源设备模块边界探针：IOPS 电源清单（公开 + 私有按类型）、变化通知频率、单次读取开销。
// 只读。不打印 Accessory Identifier、序列号等设备唯一标识（按键名脱敏）。
// 编译：xcrun swiftc -O iops_watch.swift -o iops_watch
// 用法：./iops_watch [观察秒数，默认 60]
import Foundation
import IOKit.ps

let watchSeconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let redactKeys: Set<String> = ["Accessory Identifier", "Serial Number", "Hardware Serial Number", "Battery Serial Number"]

func redact(_ d: [String: Any]) -> [String: Any] {
    var out = d
    for k in d.keys where redactKeys.contains(k) { out[k] = "<redacted len=\((d[k] as? String)?.count ?? 0)>" }
    return out
}

func dump(_ d: [String: Any], indent: String = "  ") {
    for k in d.keys.sorted() { print("\(indent)\(k) = \(d[k]!)") }
}

func threadCPUNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

// MARK: 公开路径
print("=== \(Date())")
let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
print("IOPSCopyPowerSourcesList count=\(list.count)")
print("IOPSGetProvidingPowerSourceType = \(IOPSGetProvidingPowerSourceType(blob).takeUnretainedValue())")
for (i, ps) in list.enumerated() {
    guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
    print("-- public[\(i)]"); dump(redact(d))
}

// MARK: 私有按类型（D05：生产代码放 CSysPrivate）
typealias ByTypeFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
if let sym = dlsym(h, "IOPSCopyPowerSourcesByType") {
    let fn = unsafeBitCast(sym, to: ByTypeFn.self)
    for t: Int32 in [0, 1, 2, 3, 4] {
        guard let r = fn(t)?.takeRetainedValue() else { print("ByType(\(t)) = nil"); continue }
        let l = IOPSCopyPowerSourcesList(r).takeRetainedValue() as [CFTypeRef]
        print("ByType(\(t)) count=\(l.count)")
        if t == 0 {
            for (i, ps) in l.enumerated() {
                guard let d = IOPSGetPowerSourceDescription(r, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
                print("-- byType0[\(i)]"); dump(redact(d))
            }
        }
    }
} else { print("dlsym(IOPSCopyPowerSourcesByType) absent") }

// MARK: 单次读取开销（公开快照 + 列表 + 逐个描述）
var samples: [Double] = []
for _ in 0..<50 {
    let c0 = threadCPUNanos()
    let b = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let l = IOPSCopyPowerSourcesList(b).takeRetainedValue() as [CFTypeRef]
    for ps in l { _ = IOPSGetPowerSourceDescription(b, ps) }
    samples.append(Double(threadCPUNanos() - c0) / 1000)
}
samples.sort()
print(String(format: "read cost (thread CPU, us): p50=%.1f p90=%.1f max=%.1f", samples[25], samples[45], samples[49]))

// MARK: 变化通知（公开 + 私有配件）
let start = Date()
var counts = (ps: 0, acc: 0)
var lastSummary = ""
func summary() -> String {
    let b = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let l = IOPSCopyPowerSourcesList(b).takeRetainedValue() as [CFTypeRef]
    return l.compactMap { IOPSGetPowerSourceDescription(b, $0)?.takeUnretainedValue() as? [String: Any] }
        .map { "\($0["Type"] ?? "?")|\($0["Current Capacity"] ?? "?")%|\($0["Power Source State"] ?? "?")|tte=\($0["Time to Empty"] ?? "?")|V=\($0["Voltage"] ?? "?")" }
        .joined(separator: "; ")
}
let cb: IOPowerSourceCallbackType = { _ in
    counts.ps += 1
    let s = summary()
    print(String(format: "[%6.1f s] ps notify #%d %@", Date().timeIntervalSince(start), counts.ps, s == lastSummary ? "(unchanged)" : s))
    lastSummary = s
}
if let src = IOPSNotificationCreateRunLoopSource(cb, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
}
typealias AccNotifyFn = @convention(c) (IOPowerSourceCallbackType, UnsafeMutableRawPointer?) -> Unmanaged<CFRunLoopSource>?
if let sym = dlsym(h, "IOPSAccNotificationCreateRunLoopSource") {
    let fn = unsafeBitCast(sym, to: AccNotifyFn.self)
    let accCB: IOPowerSourceCallbackType = { _ in
        counts.acc += 1
        print(String(format: "[%6.1f s] acc notify #%d", Date().timeIntervalSince(start), counts.acc))
    }
    if let src = fn(accCB, nil)?.takeRetainedValue() { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }
}
lastSummary = summary()
print("watching \(Int(watchSeconds)) s …")
RunLoop.main.run(until: Date().addingTimeInterval(watchSeconds))
print("notify totals over \(Int(watchSeconds)) s: ps=\(counts.ps) acc=\(counts.acc)")
