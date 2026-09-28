// Replicates Stats' driveTopology() (readers.swift:618) + prints the full parent chain classes for each physical drive
import Foundation
import IOKit
import IOKit.storage
func cls(_ e: io_registry_entry_t) -> String { var n = [CChar](repeating: 0, count: 128); IOObjectGetClass(e, &n); return String(cString: n) }
var it: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDeviceClass), &it)
while case let dev = IOIteratorNext(it), dev != 0 {
    let dc = IORegistryEntryCreateCFProperty(dev, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    let pc = IORegistryEntryCreateCFProperty(dev, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    if (pc?["Physical Interconnect"] as? String) == "Virtual Interface" { IOObjectRelease(dev); continue }
    var entry = dev; IOObjectRetain(entry)
    var chain: [String] = []; var path: [Int] = []; var enclosure = ""; var inside = false
    for _ in 0..<32 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
        IOObjectRelease(entry); entry = parent
        var loc = [CChar](repeating: 0, count: 128)
        let hasLoc = IORegistryEntryGetLocationInPlane(entry, kIOServicePlane, &loc) == KERN_SUCCESS
        chain.append(cls(entry) + (hasLoc ? "@" + String(cString: loc) : ""))
        if IOObjectConformsTo(entry, "IOPCIDevice") != 0 || IOObjectConformsTo(entry, "IOPCIBridge") != 0 {
            inside = true
            if hasLoc, let v = Int(String(cString: loc).split(separator: ",").first.map(String.init) ?? "", radix: 16) { path.append(v) }
        } else if inside && enclosure.isEmpty {
            var p = [CChar](repeating: 0, count: 1024); if IORegistryEntryGetPath(entry, kIOServicePlane, &p) == KERN_SUCCESS { enclosure = String(cString: p) }
        }
    }
    IOObjectRelease(entry)
    print("\(dc?["Product Name"] ?? "?") SN=\(dc?["Serial Number"] ?? "?") interconnect=\(pc?["Physical Interconnect"] ?? "?")/\(pc?["Physical Interconnect Location"] ?? "?")")
    print("  Stats slotPath=\(Array(path.reversed())) enclosure=\(enclosure.split(separator: "/").suffix(3).joined(separator: "/"))")
    print("  chain: \(chain.prefix(14).joined(separator: " <- "))")
    IOObjectRelease(dev)
}
