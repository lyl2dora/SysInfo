// Review probe: which UUID does each API report for '/' vs the Data volume?
import Foundation
import DiskArbitration
let s = DASessionCreate(kCFAllocatorDefault)!
for p in ["/", "/System/Volumes/Data", "/Volumes/External"] {
    let u = URL(fileURLWithPath: p)
    let v = try? u.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIdentifierKey])
    var desc = ""
    if let d = DADiskCreateFromVolumePath(kCFAllocatorDefault, s, u as CFURL), let dict = DADiskCopyDescription(d) as? [String: Any] {
        let vu = dict[kDADiskDescriptionVolumeUUIDKey as String].map { CFUUIDCreateString(nil, ($0 as! CFUUID)) as String } ?? "nil"
        let mu = dict[kDADiskDescriptionMediaUUIDKey as String].map { CFUUIDCreateString(nil, ($0 as! CFUUID)) as String } ?? "nil"
        desc = "DA bsd=\(String(cString: DADiskGetBSDName(d)!)) DAVolumeUUID=\(vu) DAMediaUUID=\(mu)"
    }
    print("\(p): URL volumeUUIDString=\(v?.volumeUUIDString ?? "nil") | \(desc)")
}
