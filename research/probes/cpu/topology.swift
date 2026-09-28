// Probe: CPU topology on Apple silicon (sysctl hw.perflevel*, IORegistry AppleARMPE children, pmgr voltage-states*)
import Foundation
import IOKit

func sysctlInt(_ n: String) -> Int64? { var v: Int64 = 0; var s = 8; return sysctlbyname(n, &v, &s, nil, 0) == 0 ? v : nil }
func sysctlStr(_ n: String) -> String? {
    var s = 0; guard sysctlbyname(n, nil, &s, nil, 0) == 0, s > 0 else { return nil }
    var b = [CChar](repeating: 0, count: s); guard sysctlbyname(n, &b, &s, nil, 0) == 0 else { return nil }
    return String(cString: b)
}
print("== sysctl ==")
print("brand:", sysctlStr("machdep.cpu.brand_string") ?? "nil")
print("hw.ncpu:", sysctlInt("hw.ncpu") ?? -1, " nperflevels:", sysctlInt("hw.nperflevels") ?? -1)
let nl = Int(sysctlInt("hw.nperflevels") ?? 0)
for i in 0..<max(nl, 3) {
    let p = "hw.perflevel\(i)."
    print("perflevel\(i): name=\(sysctlStr(p+"name") ?? "nil") physical=\(sysctlInt(p+"physicalcpu").map{String($0)} ?? "nil") logical=\(sysctlInt(p+"logicalcpu").map{String($0)} ?? "nil") cpusperl2=\(sysctlInt(p+"cpusperl2").map{String($0)} ?? "nil") l2=\(sysctlInt(p+"l2cachesize").map{String($0)} ?? "nil") l1d=\(sysctlInt(p+"l1dcachesize").map{String($0)} ?? "nil")")
}

func u32(_ d: Data) -> UInt32? { d.count >= 4 ? d.withUnsafeBytes { $0.load(as: UInt32.self) } : nil }
func str(_ d: Data) -> String { String(data: d, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "?" }

print("\n== IORegistry: AppleARMPE children (Stats method) ==")
var it: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &it)
var clusterOf: [Int: (type: String, cluster: UInt32, compat: String)] = [:]
while case let svc = IOIteratorNext(it), svc != 0 {
    var ch: io_iterator_t = 0
    IORegistryEntryGetChildIterator(svc, kIOServicePlane, &ch)
    while case let c = IOIteratorNext(ch), c != 0 {
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(c, &nameBuf)
        let name = String(cString: nameBuf)
        var props: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(c, &props, kCFAllocatorDefault, 0)
        let p = (props?.takeRetainedValue() as? [String: Any]) ?? [:]
        if name == "cpus" {
            let keys = p.keys.sorted()
            print("cpus node keys:", keys)
            for k in ["e-core-count","p-core-count","m-core-count","s-core-count","cpu-cluster-count","max_cpus"] {
                print("  \(k) =", (p[k] as? Data).flatMap(u32).map{String($0)} ?? "ABSENT")
            }
        } else if name.hasPrefix("cpu"), let idx = Int(name.dropFirst(3)) {
            let type = (p["cluster-type"] as? Data).map(str) ?? "?"
            let cid = (p["cluster-id"] as? Data).flatMap(u32) ?? 999
            let compat = (p["compatible"] as? Data).map { String(data: $0, encoding: .utf8)?.replacingOccurrences(of: "\0", with: ",") ?? "?" } ?? "?"
            clusterOf[idx] = (type, cid, compat)
        }
        IOObjectRelease(c)
    }
    IOObjectRelease(ch); IOObjectRelease(svc)
}
IOObjectRelease(it)
for k in clusterOf.keys.sorted() { let v = clusterOf[k]!; print("cpu\(k): cluster-type=\(v.type) cluster-id=\(v.cluster) compatible=\(v.compat)") }

print("\n== pmgr voltage-states* (AppleARMIODevice name=pmgr) ==")
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it)
while case let svc = IOIteratorNext(it), svc != 0 {
    defer { IOObjectRelease(svc) }
    var nameBuf = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(svc, &nameBuf)
    guard String(cString: nameBuf) == "pmgr" else { continue }
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
    let p = (props?.takeRetainedValue() as? [String: Any]) ?? [:]
    let keys = p.keys.filter { $0.hasPrefix("voltage-states") }.sorted { a, b in
        let na = Int(a.dropFirst(14).prefix(while: { $0.isNumber })) ?? 0, nb = Int(b.dropFirst(14).prefix(while: { $0.isNumber })) ?? 0
        return na != nb ? na < nb : a < b }
    for k in keys {
        guard let d = p[k] as? Data else { continue }
        var pairs: [(UInt32, UInt32)] = []
        d.withUnsafeBytes { raw in
            var o = 0
            while o + 8 <= d.count { pairs.append((raw.load(fromByteOffset: o, as: UInt32.self), raw.load(fromByteOffset: o+4, as: UInt32.self))); o += 8 }
        }
        // Stats' M4+ decoding: freq/1000 => MHz (freq stored in kHz)
        let mhz = pairs.map { $0.0 / 1000 }
        let mv = pairs.map { $0.1 }
        print("\(k) [\(pairs.count) states] freq(raw/1000)=\(mhz) mV=\(mv)")
    }
}
IOObjectRelease(it)
