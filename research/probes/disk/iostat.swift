// Block-level I/O counters (IOBlockStorageDriver "Statistics") + Stats' volume->parent walk + per-process rusage for own I/O
import Foundation
import IOKit
import IOKit.storage
import DiskArbitration

func props(_ e: io_registry_entry_t) -> NSDictionary? {
    var p: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(e, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return p?.takeRetainedValue()
}
func cls(_ e: io_registry_entry_t) -> String { var n = [CChar](repeating: 0, count: 128); IOObjectGetClass(e, &n); return String(cString: n) }

struct Snap { var rb: Int64; var wb: Int64; var ro: Int64; var wo: Int64; var rt: Int64; var wt: Int64; var re: Int64; var we: Int64 }
func stat(_ d: NSDictionary) -> Snap {
    func g(_ k: String) -> Int64 { (d[k] as? NSNumber)?.int64Value ?? 0 }
    return Snap(rb: g("Bytes (Read)"), wb: g("Bytes (Write)"), ro: g("Operations (Read)"), wo: g("Operations (Write)"), rt: g("Total Time (Read)"), wt: g("Total Time (Write)"), re: g("Errors (Read)"), we: g("Errors (Write)"))
}

// physical drives: IOBlockStorageDriver whose provider is a real device; keyed by whole-disk BSD name under it
func drivers() -> [String: (Snap, String)] {
    var out: [String: (Snap, String)] = [:]
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it)
    while case let drv = IOIteratorNext(it), drv != 0 {
        defer { IOObjectRelease(drv) }
        guard let p = props(drv), let s = p["Statistics"] as? NSDictionary else { continue }
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(drv, kIOServicePlane, &child) == KERN_SUCCESS else { continue }
        let bsd = (props(child)?["BSD Name"] as? String) ?? "?"
        IOObjectRelease(child)
        var parent: io_registry_entry_t = 0
        IORegistryEntryGetParentEntry(drv, kIOServicePlane, &parent)
        let pc = cls(parent); IOObjectRelease(parent)
        out[bsd] = (stat(s), pc)
    }
    IOObjectRelease(it)
    return out
}

// Stats' getDeviceIOParent(): walk up from the volume's IOMedia until a Statistics dict with "Bytes (Read)" appears
func statsWalk(_ path: String) -> (String, Snap)? {
    guard let session = DASessionCreate(kCFAllocatorDefault), let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL) else { return nil }
    var entry = DADiskCopyIOMedia(disk)
    var trail: [String] = []
    for _ in 0..<8 {
        var parent: io_registry_entry_t = 0
        let r = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
        IOObjectRelease(entry)
        guard r == KERN_SUCCESS, parent != 0 else { return nil }
        entry = parent
        trail.append(cls(entry))
        if let p = props(entry), let s = p["Statistics"] as? NSDictionary, s["Bytes (Read)"] != nil {
            IOObjectRelease(entry)
            return (trail.joined(separator: " -> "), stat(s))
        }
    }
    IOObjectRelease(entry)
    return nil
}

func rusage() -> (Int64, Int64, Int64) {
    var u = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &u) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
    return r == 0 ? (Int64(u.ri_diskio_bytesread), Int64(u.ri_diskio_byteswritten), Int64(u.ri_logical_writes)) : (-1, -1, -1)
}

let a = drivers(); let wa = [("/", statsWalk("/")), ("/Volumes/External", statsWalk("/Volumes/External"))]; let ua = rusage()
print("physical drivers (whole-disk BSD -> provider class):")
for (k, v) in a.sorted(by: { $0.key < $1.key }) { print("  \(k) <- \(v.1)  readB=\(v.0.rb) writeB=\(v.0.wb) readOps=\(v.0.ro) writeOps=\(v.0.wo) readTimeNs=\(v.0.rt) writeTimeNs=\(v.0.wt) errR=\(v.0.re) errW=\(v.0.we)") }
for (p, w) in wa { print("Stats walk \(p): \(w?.0 ?? "nil")") }

// workload: 512 MiB random write with F_NOCACHE + fsync, then read back uncached
let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path + "/io_workload.bin"
let chunk = 8 << 20
var buf = [UInt8](repeating: 0, count: chunk)
arc4random_buf(&buf, chunk)
let t0 = Date()
let fd = open(file, O_CREAT | O_TRUNC | O_RDWR, 0o644)
_ = fcntl(fd, F_NOCACHE, 1)
for _ in 0..<64 { _ = buf.withUnsafeBytes { write(fd, $0.baseAddress, chunk) } }
_ = fcntl(fd, F_FULLFSYNC)
lseek(fd, 0, SEEK_SET)
var total = 0
while true { let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }; if n <= 0 { break }; total += n }
close(fd)
let dt = Date().timeIntervalSince(t0)
unlink(file)
Thread.sleep(forTimeInterval: 0.5)
let b = drivers(); let wb = [("/", statsWalk("/")), ("/Volumes/External", statsWalk("/Volumes/External"))]; let ub = rusage()
print(String(format: "\nworkload: wrote 512 MiB + read back %d MiB uncached in %.2fs", total >> 20, dt))
print("deltas per physical driver:")
for (k, v) in b.sorted(by: { $0.key < $1.key }) { if let o = a[k] { print("  \(k): dReadB=\(v.0.rb - o.0.rb) dWriteB=\(v.0.wb - o.0.wb) dReadOps=\(v.0.ro - o.0.ro) dWriteOps=\(v.0.wo - o.0.wo) dReadTimeMs=\((v.0.rt - o.0.rt) / 1_000_000) dWriteTimeMs=\((v.0.wt - o.0.wt) / 1_000_000)") } }
for i in 0..<2 { if let x = wa[i].1, let y = wb[i].1 { print("Stats walk \(wa[i].0) delta: dReadB=\(y.1.rb - x.1.rb) dWriteB=\(y.1.wb - x.1.wb)") } }
print("own proc_pid_rusage: diskio_bytesread \(ua.0)->\(ub.0) (d=\(ub.0 - ua.0))  diskio_byteswritten \(ua.1)->\(ub.1) (d=\(ub.1 - ua.1))  logical_writes d=\(ub.2 - ua.2)")
