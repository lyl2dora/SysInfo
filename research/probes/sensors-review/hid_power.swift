// hid_power.swift - read HID PMU current (ff08/2) and voltage (ff08/3) services, event type 25 (power), keyed by name+registryID.
// Usage: hid_power -> one line per service: name rid value. Read-only.
import Foundation
import IOKit
import IOKit.hid
typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
typealias SetMatchFn = @convention(c) (AnyObject, CFDictionary) -> Int32
typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double
typealias GetIntFn = @convention(c) (AnyObject, Int32) -> Int
let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
let create = unsafeBitCast(dlsym(h, "IOHIDEventSystemClientCreate"), to: CreateFn.self)
let setMatch = unsafeBitCast(dlsym(h, "IOHIDEventSystemClientSetMatching"), to: SetMatchFn.self)
let copyEvent = unsafeBitCast(dlsym(h, "IOHIDServiceClientCopyEvent"), to: CopyEventFn.self)
let getFloat = unsafeBitCast(dlsym(h, "IOHIDEventGetFloatValue"), to: GetFloatFn.self)
let getInt = unsafeBitCast(dlsym(h, "IOHIDEventGetIntegerValue"), to: GetIntFn.self)
for usage in [2, 3] {
    let c = create(kCFAllocatorDefault)!.takeRetainedValue()
    _ = setMatch(c, ["PrimaryUsagePage": 0xff08, "PrimaryUsage": usage] as CFDictionary)
    let svcs = (IOHIDEventSystemClientCopyServices(unsafeBitCast(c, to: IOHIDEventSystemClient.self)) as? [AnyObject]) ?? []
    var rows: [String] = []
    for s in svcs {
        let sc = unsafeBitCast(s, to: IOHIDServiceClient.self)
        let name = IOHIDServiceClientCopyProperty(sc, "Product" as CFString) as? String ?? "?"
        let rid = (IOHIDServiceClientGetRegistryID(sc) as? NSNumber)?.uint64Value ?? 0
        guard let ev = copyEvent(s, 25, 0, 0)?.takeRetainedValue() else { rows.append("\(name) rid=\(String(rid, radix: 16)) NULL"); continue }
        // fields of kIOHIDEventTypePower: 0 measurement, 1 type, 2 subtype
        rows.append(String(format: "%@ rid=%llx meas=%.4f type=%ld subtype=%ld", name, rid, getFloat(ev, 25 << 16), getInt(ev, 25 << 16 | 1), getInt(ev, 25 << 16 | 2)))
    }
    print("== usage \(usage) (\(usage == 2 ? "current" : "voltage")): \(svcs.count) services")
    rows.sorted().forEach { print("  " + $0) }
}
