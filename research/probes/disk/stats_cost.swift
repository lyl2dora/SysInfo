// Cost of Stats' per-tick patterns on this Mac: ps spawn (ProcessReader), DASession per read (Capacity/ActivityReader),
// IORegistryEntryCreateCFProperties over each drive subtree (SMARTReader.physicalDriveDetails), mountedVolumeURLs
import Foundation
import DiskArbitration
import IOKit
import IOKit.storage

func time(_ label: String, _ n: Int = 5, _ f: () -> Void) {
    var best = Double.infinity, sum = 0.0
    for _ in 0..<n { let t = Date(); f(); let d = Date().timeIntervalSince(t) * 1000; best = min(best, d); sum += d }
    print(String(format: "%-70@ best=%.2f ms avg=%.2f ms", label as NSString, best, sum / Double(n)))
}

time("ps -Aceo pid,args -r spawn+read (Stats ProcessReader)") {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-Aceo pid,args", "-r"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); _ = d.count
}
let psOut: String = {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-Aceo pid,args", "-r"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(data: d, encoding: .utf8) ?? ""
}()
print("ps output lines=\(psOut.split(separator: "\n").count) first: \(psOut.split(separator: "\n").prefix(3).map(String.init))")

time("mountedVolumeURLs(.skipHiddenVolumes)") { _ = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) }
time("DASessionCreate + DADiskCreateFromVolumePath + DADiskCopyDescription x2 volumes") {
    let s = DASessionCreate(kCFAllocatorDefault)!
    for p in ["/", "/Volumes/External"] { if let d = DADiskCreateFromVolumePath(kCFAllocatorDefault, s, URL(fileURLWithPath: p) as CFURL) { _ = DADiskCopyDescription(d) } }
}

func allProps(_ e: io_registry_entry_t) { var p: Unmanaged<CFMutableDictionary>?; if IORegistryEntryCreateCFProperties(e, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS { _ = p?.takeRetainedValue() } }
time("SMARTReader-style: all block devices, full props of device/driver/whole + recursive subtree") {
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDeviceClass), &it)
    while case let dev = IOIteratorNext(it), dev != 0 {
        allProps(dev)
        var drv: io_registry_entry_t = 0
        if IORegistryEntryGetChildEntry(dev, kIOServicePlane, &drv) == KERN_SUCCESS {
            allProps(drv)
            var whole: io_registry_entry_t = 0
            if IORegistryEntryGetChildEntry(drv, kIOServicePlane, &whole) == KERN_SUCCESS {
                allProps(whole)
                var sub: io_iterator_t = 0
                if IORegistryEntryCreateIterator(whole, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &sub) == KERN_SUCCESS {
                    while case let c = IOIteratorNext(sub), c != 0 { if IOObjectConformsTo(c, "IOMedia") != 0 { allProps(c) }; IOObjectRelease(c) }
                    IOObjectRelease(sub)
                }
                IOObjectRelease(whole)
            }
            IOObjectRelease(drv)
        }
        IOObjectRelease(dev)
    }
    IOObjectRelease(it)
}
time("lean alternative: only 'Statistics' property of each IOBlockStorageDriver") {
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it)
    while case let drv = IOIteratorNext(it), drv != 0 { _ = IORegistryEntryCreateCFProperty(drv, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(); IOObjectRelease(drv) }
    IOObjectRelease(it)
}
time("CSDiskSpaceGetRecoveryEstimate(/)", 3) { _ = CSDiskSpaceGetRecoveryEstimate(URL(fileURLWithPath: "/") as CFURL) }
time("URL volumeAvailableCapacityForImportantUsage(/) uncached", 3) {
    var u = URL(fileURLWithPath: "/"); u.removeAllCachedResourceValues(); _ = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
}
