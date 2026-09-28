// Per-APFS-volume counters (AppleAPFSVolume "Statistics": Bytes read/written by user, to block device)
import Foundation
import IOKit
func volStats(_ bsd: String) -> [String: Int64] {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd)); defer { IOObjectRelease(s) }
    let d = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: NSNumber] ?? [:]
    return d.filter { $0.key.hasPrefix("Bytes") || $0.key.contains("requests") }.mapValues { $0.int64Value }
}
let a = volStats("disk3s5"), sysA = volStats("disk3s1")
let path = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path + "/apfsvol.bin"
var buf = [UInt8](repeating: 0, count: 64 << 20); arc4random_buf(&buf, buf.count)
let fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644); _ = buf.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; _ = fcntl(fd, F_FULLFSYNC); close(fd); unlink(path)
Thread.sleep(forTimeInterval: 0.5)
let b = volStats("disk3s5"), sysB = volStats("disk3s1")
print("AppleAPFSVolume disk3s5 (Data) keys: \(a.keys.sorted())")
for k in a.keys.sorted() { print("  Data   \(k): \(a[k]!) -> \(b[k] ?? -1)  d=\((b[k] ?? 0) - a[k]!)") }
for k in sysA.keys.sorted() { print("  System \(k): d=\((sysB[k] ?? 0) - sysA[k]!)") }
