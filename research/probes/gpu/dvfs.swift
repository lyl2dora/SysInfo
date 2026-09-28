// Probe: decode pmgr "voltage-statesN" DVFS tables (pairs of little-endian UInt32: freq, voltage mV)
// build: xcrun swiftc -O -o dvfs dvfs.swift -framework IOKit
import Foundation
import IOKit

var it = io_iterator_t()
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it)
while case let e = IOIteratorNext(it), e != 0 {
    var name = [CChar](repeating: 0, count: 128)
    IORegistryEntryGetName(e, &name)
    guard String(cString: name) == "pmgr" else { IOObjectRelease(e); continue }
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0)
    let d = props!.takeRetainedValue() as NSDictionary
    let keys = (d.allKeys as! [String]).filter { $0.hasPrefix("voltage-states") }.sorted {
        let a = Int($0.dropFirst(14).prefix { $0.isNumber }) ?? 0, b = Int($1.dropFirst(14).prefix { $0.isNumber }) ?? 0
        return a == b ? $0 < $1 : a < b
    }
    for k in keys {
        guard let data = d[k] as? Data else { continue }
        var pairs: [(UInt32, UInt32)] = []
        data.withUnsafeBytes { raw in
            let n = raw.count / 8
            for i in 0..<n { pairs.append((raw.load(fromByteOffset: i * 8, as: UInt32.self), raw.load(fromByteOffset: i * 8 + 4, as: UInt32.self))) }
        }
        let maxF = pairs.map { $0.0 }.max() ?? 0
        // Heuristic units: >= 1e8 => Hz; otherwise kHz
        let unit = maxF >= 100_000_000 ? "Hz" : "kHz"
        let mhz = pairs.map { unit == "Hz" ? Double($0.0) / 1e6 : Double($0.0) / 1e3 }
        print("\(k) [\(pairs.count) states, raw unit \(unit)]: " + zip(mhz, pairs).map { String(format: "%.0fMHz@%umV", $0.0, $0.1.1) }.joined(separator: " "))
    }
    for k in ["mgpu-count-per-die", "mcx-fast-pcpu-frequency"] {
        if let v = d[k] as? Data { print("\(k) = \(v.map { String(format: "%02x", $0) }.joined())") }
    }
    IOObjectRelease(e)
}
IOObjectRelease(it)
