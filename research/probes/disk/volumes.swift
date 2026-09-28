// Volume list + capacity probe: FileManager/URLResourceValues, statfs, getattrlist, CSDiskSpaceGetRecoveryEstimate, DiskArbitration description, APFS role from IORegistry
import Foundation
import CoreServices
import DiskArbitration
import IOKit

func gb(_ v: Int64?) -> String { v.map { String(format: "%.2fGB", Double($0) / 1e9) } ?? "nil" }
func gbu(_ v: UInt64) -> String { String(format: "%.2fGB", Double(v) / 1e9) }

let keys: [URLResourceKey] = [
    .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey,
    .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
    .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey,
    .volumeTypeNameKey, .volumeSubtypeKey, .volumeMountFromLocationKey, .volumeIsEncryptedKey, .volumeSupportsFileCloningKey,
    .volumeIsAutomountedKey
]

let allURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
let visible = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
print("mountedVolumeURLs: all=\(allURLs.count) skipHiddenVolumes=\(visible.count)")
print("visible:", visible.map { $0.path })

let session = DASessionCreate(kCFAllocatorDefault)!

func apfsRole(bsd: String) -> String {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
    guard svc != 0 else { return "-" }
    defer { IOObjectRelease(svc) }
    var r = ""
    if let role = IORegistryEntryCreateCFProperty(svc, "Role" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String] { r = role.joined(separator: ",") }
    if let rv = IORegistryEntryCreateCFProperty(svc, "RoleValue" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { r += "(\(rv))" }
    if let s = IORegistryEntryCreateCFProperty(svc, "Sealed" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { r += " sealed=\(s)" }
    return r.isEmpty ? "-" : r
}

// getattrlist volume attributes
struct VolAttrBuf { var length: UInt32 = 0; var avail: off_t = 0; var used: off_t = 0; var quota: off_t = 0; var reserved: off_t = 0 }
func volAttrs(_ path: String) -> (avail: Int64, used: Int64, quota: Int64, reserved: Int64)? {
    var al = attrlist()
    al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    al.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEAVAIL) | attrgroup_t(ATTR_VOL_SPACEUSED) | attrgroup_t(ATTR_VOL_QUOTA_SIZE) | attrgroup_t(ATTR_VOL_RESERVED_SIZE)
    var buf = [UInt8](repeating: 0, count: 64)
    let rc = buf.withUnsafeMutableBytes { getattrlist(path, &al, $0.baseAddress, $0.count, 0) }
    guard rc == 0 else { return nil }
    return buf.withUnsafeBytes { p in
        (p.load(fromByteOffset: 4, as: Int64.self), p.load(fromByteOffset: 12, as: Int64.self), p.load(fromByteOffset: 20, as: Int64.self), p.load(fromByteOffset: 28, as: Int64.self))
    }
}

for url in allURLs {
    let t0 = Date()
    guard let v = try? url.resourceValues(forKeys: Set(keys)) else { print("\n## \(url.path): resourceValues failed"); continue }
    let dt = Date().timeIntervalSince(t0) * 1000
    print("\n## \(url.path)  name=\(v.volumeName ?? "?") localized=\(v.volumeLocalizedName ?? "?") (resourceValues \(String(format: "%.1f", dt)) ms)")
    print("   typeName=\(v.volumeTypeName ?? "nil") subtype=\(v.volumeSubtype.map(String.init) ?? "nil") format=\(v.volumeLocalizedFormatDescription ?? "nil") mountFrom=\(v.volumeMountFromLocation ?? "nil")")
    print("   internal=\(v.volumeIsInternal.map(String.init) ?? "nil") removable=\(v.volumeIsRemovable.map(String.init) ?? "nil") ejectable=\(v.volumeIsEjectable.map(String.init) ?? "nil") local=\(v.volumeIsLocal.map(String.init) ?? "nil") browsable=\(v.volumeIsBrowsable.map(String.init) ?? "nil") root=\(v.volumeIsRootFileSystem.map(String.init) ?? "nil") ro=\(v.volumeIsReadOnly.map(String.init) ?? "nil") encrypted=\(v.volumeIsEncrypted.map(String.init) ?? "nil") automounted=\(v.volumeIsAutomounted.map(String.init) ?? "nil")")
    print("   total=\(gb(v.volumeTotalCapacity.map(Int64.init))) available=\(gb(v.volumeAvailableCapacity.map(Int64.init))) important=\(gb(v.volumeAvailableCapacityForImportantUsage)) opportunistic=\(gb(v.volumeAvailableCapacityForOpportunisticUsage)) uuid=\(v.volumeUUIDString ?? "nil")")
    var s = statfs()
    if statfs(url.path, &s) == 0 {
        let fstype = withUnsafeBytes(of: s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let from = withUnsafeBytes(of: s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let bs = Int64(s.f_bsize)
        print("   statfs: fstype=\(fstype) from=\(from) total=\(gb(Int64(s.f_blocks) * bs)) bavail=\(gb(Int64(s.f_bavail) * bs)) bfree=\(gb(Int64(s.f_bfree) * bs)) flags=0x\(String(s.f_flags, radix: 16)) fssubtype=\(s.f_fssubtype)")
        if fstype == "apfs" {
            let t1 = Date()
            let est = CSDiskSpaceGetRecoveryEstimate(url as CFURL)
            print("   CSDiskSpaceGetRecoveryEstimate=\(gbu(est)) (\(String(format: "%.1f", Date().timeIntervalSince(t1) * 1000)) ms)  statfs-bavail+est=\(gb(Int64(s.f_bavail) * bs + Int64(est)))")
        }
    }
    if let a = volAttrs(url.path) { print("   getattrlist: SPACEAVAIL=\(gb(a.avail)) SPACEUSED(volume)=\(gb(a.used)) QUOTA=\(gb(a.quota)) RESERVED=\(gb(a.reserved))") }
    if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL), let bsdc = DADiskGetBSDName(disk) {
        let bsd = String(cString: bsdc)
        let d = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        func k(_ key: CFString) -> String { d[key as String].map { "\($0)" } ?? "nil" }
        print("   DA: bsd=\(bsd) kind=\(k(kDADiskDescriptionVolumeKindKey)) mediaRemovable=\(k(kDADiskDescriptionMediaRemovableKey)) mediaEjectable=\(k(kDADiskDescriptionMediaEjectableKey)) deviceInternal=\(k(kDADiskDescriptionDeviceInternalKey)) protocol=\(k(kDADiskDescriptionDeviceProtocolKey)) model=\(k(kDADiskDescriptionDeviceModelKey)) mediaName=\(k(kDADiskDescriptionMediaNameKey)) volNet=\(k(kDADiskDescriptionVolumeNetworkKey)) encrypted=\(k(kDADiskDescriptionMediaEncryptedKey))")
        print("   APFS role: \(apfsRole(bsd: bsd))")
        print("   Stats-filter(pathComponents==1 || [1]==Volumes): \(url.pathComponents.count == 1 || (url.pathComponents.count > 1 && url.pathComponents[1] == "Volumes"))")
    } else {
        print("   DA: no disk for volume path (network/virtual fs)")
    }
}
