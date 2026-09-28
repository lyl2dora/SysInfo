// hid_vs_smc.swift - read HID PMU temps (private IOHIDEventSystemClient, resolved via dlsym) and ALL SMC T* keys at the
// same instant; for each HID sensor list SMC keys within 0.1 C to find which SMC keys back the HID values. Read-only.
import Foundation
import IOKit
import IOKit.hid

typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
typealias SetMatchFn = @convention(c) (AnyObject, CFDictionary) -> Int32
typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double
let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
let create = unsafeBitCast(dlsym(h, "IOHIDEventSystemClientCreate"), to: CreateFn.self)
let setMatch = unsafeBitCast(dlsym(h, "IOHIDEventSystemClientSetMatching"), to: SetMatchFn.self)
let copyEvent = unsafeBitCast(dlsym(h, "IOHIDServiceClientCopyEvent"), to: CopyEventFn.self)
let getFloat = unsafeBitCast(dlsym(h, "IOHIDEventGetFloatValue"), to: GetFloatFn.self)

// ---- SMC (raw 80-byte buffer) ----
var conn: io_connect_t = 0
func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func call(_ i: [UInt8]) -> [UInt8]? { var o = [UInt8](repeating: 0, count: 80); var n = 80
    let kr = i.withUnsafeBytes { ip in o.withUnsafeMutableBytes { op in IOConnectCallStructMethod(conn, 2, ip.baseAddress, 80, op.baseAddress, &n) } }
    return kr == KERN_SUCCESS && o[40] == 0 ? o : nil }
func smcFloat(_ k: String) -> Double? {
    var i = [UInt8](repeating: 0, count: 80); withUnsafeBytes(of: fcc(k)) { for j in 0..<4 { i[j] = $0[j] } }; i[42] = 9
    guard let info = call(i) else { return nil }
    let size = info[28...31].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    let type = String(bytes: info[32...35].reversed(), encoding: .ascii) ?? ""
    for j in 28...31 { i[j] = info[j] }; i[42] = 5
    guard let r = call(i) else { return nil }
    let b = Array(r[48..<80])
    if type == "flt " && size == 4 { return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) }
    if type == "ioft" && size == 8 { return Double(b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536 }
    return nil
}
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); IOServiceOpen(svc, mach_task_self_, 0, &conn)
let tkeys = CommandLine.arguments.dropFirst().map { String($0) }

// ---- HID ----
let client = create(kCFAllocatorDefault)!.takeRetainedValue()
_ = setMatch(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
let services = (IOHIDEventSystemClientCopyServices(unsafeBitCast(client, to: IOHIDEventSystemClient.self)) as? [AnyObject]) ?? []
var hid: [(String, UInt64, Double)] = []
for s in services {
    let sc = unsafeBitCast(s, to: IOHIDServiceClient.self)
    let name = IOHIDServiceClientCopyProperty(sc, "Product" as CFString) as? String ?? "?"
    let rid = (IOHIDServiceClientGetRegistryID(sc) as? NSNumber)?.uint64Value ?? 0
    guard let ev = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
    hid.append((name, rid, getFloat(ev, 15 << 16)))
}
var smc: [(String, Double)] = []
for k in tkeys { if let v = smcFloat(k) { smc.append((k, v)) } }
print("HID services=\(services.count) read=\(hid.count); SMC T keys read=\(smc.count)")
for (n, rid, v) in hid.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
    let near = smc.filter { abs($0.1 - v) < 0.1 && v > 0 }.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }
    print(String(format: "%-14@ rid=0x%llx %9.3f  SMC within 0.1C: ", n as NSString, rid, v) + near.joined(separator: " "))
}
let hot = smc.filter { $0.1 > 5 && $0.1 < 130 }.sorted { $0.1 > $1.1 }.prefix(12).map { "\($0.0)=\(String(format: "%.2f", $0.1))" }
print("hottest SMC T keys: " + hot.joined(separator: " "))
