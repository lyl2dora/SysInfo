import Foundation
// The APFS Data volume is not returned by mountedVolumeURLs; check it directly by path
for p in ["/System/Volumes/Data", "/", NSHomeDirectory()] {
    let u = URL(fileURLWithPath: p)
    let v = try? u.resourceValues(forKeys: [.volumeNameKey, .volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeMountFromLocationKey])
    var al = attrlist(); al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    al.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEAVAIL) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var buf = [UInt8](repeating: 0, count: 64)
    let rc = buf.withUnsafeMutableBytes { getattrlist(p, &al, $0.baseAddress, $0.count, 0) }
    let used = rc == 0 ? buf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int64.self) } : -1
    var s = statfs(); statfs(p, &s)
    let from = withUnsafeBytes(of: s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    print("\(p): volumeName=\(v?.volumeName ?? "nil") volumeURL=\(v?.volume?.path ?? "nil") mountFrom=\(v?.volumeMountFromLocation ?? "nil") statfs.from=\(from) important=\(String(format: "%.2fGB", Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)/1e9)) SPACEUSED(volume)=\(String(format: "%.2fGB", Double(used)/1e9))")
}
var mnt: UnsafeMutablePointer<statfs>? = nil
let n = getmntinfo(&mnt, MNT_NOWAIT)
print("getmntinfo count=\(n) (mountedVolumeURLs all=16 above)")
for i in 0..<Int(n) { let m = mnt![i]; let on = withUnsafeBytes(of: m.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }; print("  \(on) flags=0x\(String(m.f_flags, radix: 16)) dontbrowse=\(m.f_flags & UInt32(MNT_DONTBROWSE) != 0) local=\(m.f_flags & UInt32(MNT_LOCAL) != 0) rootfs=\(m.f_flags & UInt32(MNT_ROOTFS) != 0)") }
