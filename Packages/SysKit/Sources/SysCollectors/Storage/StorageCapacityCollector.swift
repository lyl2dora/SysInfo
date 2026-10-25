// 容量采集器 `storage.capacity`（存储模块设计 §4.4，D54）：公开接口，blocking 通道。
//
// - 每次先强制刷新物理盘清单：RAID 组与成员状态没有通知，靠这里刷新（最多 60 s 一次，面板打开时 10 s）；
// - 容量组 = 一个 APFS 容器，或一个非 APFS 的已挂载分区。容量本来就是容器 / 阵列的属性，挂在组上，
//   不拆到 RAID 成员盘（D54）：
//   - APFS：总量取容器 `IOMedia` 的大小；可用取容器内任一已挂载卷的 `statfs`（同一容器的卷共享可用空间）；
//     卷的已用取 `getattrlist(ATTR_VOL_SPACEUSED)`；
//   - 非 APFS：直接用 `statfs`；
// - 归属：从容器（分区）向上找，先遇到 `AppleRAIDSet` 归 RAID 组，先遇到物理盘归那块盘；
//   落在磁盘映像等非物理盘上的组不要；
// - 可清除空间：只给启动卷所在的组，`volumeAvailableCapacityForImportantUsage` − `statfs` 可用，最多 60 s 一次（15–60 ms）；
// - 只看本地挂载点（`MNT_LOCAL`），不碰网络卷。
//
// 自检：getmntinfo 可用（必需）；至少找到一个容量组（提示）。

import Darwin
import Foundation
import Synchronization
import SysModel

public final class StorageCapacityCollector: Collector {
    public static let collectorID: CollectorID = "storage.capacity"
    public static let dataPath = "IORegistry（APFS 容器、AppleRAID）+ statfs + getattrlist(ATTR_VOL_SPACEUSED)"

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking

    /// 可清除空间的缓存时长，秒。
    static let purgeableCacheSeconds: Double = 60

    private struct State {
        var usable: Bool?
        var groups: [CapacityGroup] = []
        /// 上一次读到的可清除空间与读取时刻；`bytes` 为 nil（没有可清除空间或读不到）同样缓存（审计 A39）。
        var purgeable: (bytes: UInt64?, nanos: UInt64)?
    }

    private let inventory: DiskInventory
    private let state = Mutex(State())

    public init(inventory: DiskInventory = .shared) {
        self.inventory = inventory
    }

    /// 最近一次的容量组（面板组标题、详情页的卷构成）。
    public var latestGroups: [CapacityGroup] { state.withLock { $0.groups } }

    public func selfTest() -> SelfTestResult {
        let mounts = Self.mounts()
        let groups = mounts.isEmpty ? [] : Self.groups(snapshot: inventory.snapshot(refresh: true), mounts: mounts, purgeable: nil)
        let checks = [
            SelfTestCheck(name: "storage.capacity.mounts", passed: !mounts.isEmpty, detail: "local mounts=\(mounts.count)"),
            SelfTestCheck(
                name: "storage.capacity.groups", passed: !groups.isEmpty, detail: "groups=\(groups.count)", severity: .advisory),
        ]
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.usable = result.isUsable
            $0.groups = groups
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        guard state.withLock({ $0.usable }) != false else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        let snapshot = inventory.snapshot(refresh: true)
        let mounts = Self.mounts()
        guard !mounts.isEmpty else {
            return CollectorOutput(samples: [], status: .degraded, dataPath: Self.dataPath)
        }
        let cached = state.withLock { s -> UInt64?? in
            guard let p = s.purgeable, Double(time.continuousNanos &- p.nanos) / 1e9 < Self.purgeableCacheSeconds else { return nil }
            return .some(p.bytes)
        }
        let purgeable: UInt64?
        if let cached {
            purgeable = cached
        } else {
            purgeable = Self.readPurgeable()
            state.withLock { $0.purgeable = (purgeable, time.continuousNanos) }
        }
        let groups = Self.groups(snapshot: snapshot, mounts: mounts, purgeable: purgeable)
        state.withLock { $0.groups = groups }
        var samples: [Sample] = []
        for group in groups where !group.isAuxiliary {
            samples.append(Sample(id: .storageGroup(group.key, .total), value: Double(group.totalBytes), time: time))
            samples.append(Sample(id: .storageGroup(group.key, .available), value: Double(group.availableBytes), time: time))
            samples.append(Sample(id: .storageGroup(group.key, .used), value: Double(group.usedBytes), time: time))
        }
        return CollectorOutput(samples: samples, status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    // MARK: - 挂载点

    struct Mount: Sendable {
        var bsdName: String
        var mountPoint: String
        var fileSystem: String
        var totalBytes: UInt64
        var availableBytes: UInt64
    }

    /// 本地挂载点，按 BSD 名（`/dev/disk3s5` → `disk3s5`）。
    static func mounts() -> [String: Mount] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let pointer else { return [:] }
        var out: [String: Mount] = [:]
        for i in 0..<Int(count) {
            var fs = pointer[i]
            guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard from.hasPrefix("/dev/disk") else { continue }
            let bsd = String(from.dropFirst("/dev/".count))
            let on = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let block = UInt64(fs.f_bsize)
            // 同一个设备挂多次（启动卷的快照）时保留第一次出现的。
            if out[bsd] == nil {
                out[bsd] = Mount(
                    bsdName: bsd, mountPoint: on, fileSystem: type, totalBytes: fs.f_blocks * block,
                    availableBytes: fs.f_bavail * block)
            }
        }
        return out
    }

    /// 卷（或其快照）对应的挂载：启动卷挂的是快照 `disk3s1s1`。
    static func mount(of volumeBSD: String, in mounts: [String: Mount]) -> Mount? {
        if let direct = mounts[volumeBSD] { return direct }
        return mounts.first { $0.key.hasPrefix(volumeBSD + "s") }?.value
    }

    /// 卷的已用量（`ATTR_VOL_SPACEUSED`）。
    static func spaceUsed(mountPoint: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 64)
        let r = buffer.withUnsafeMutableBytes { raw in
            getattrlist(mountPoint, &list, raw.baseAddress, raw.count, 0)
        }
        guard r == 0 else { return nil }
        // 布局：u_int32_t 长度，随后是 off_t。
        let value = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return value >= 0 ? UInt64(value) : nil
    }

    /// 启动卷的可清除空间：「重要用途可用」− `statfs` 可用。读不到或不为正时为 nil。
    static func readPurgeable() -> UInt64? {
        let url = URL(fileURLWithPath: "/")
        guard let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
            let available = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
            important > Int64(available)
        else { return nil }
        return UInt64(important - Int64(available))
    }

    // MARK: - 容量组

    /// APFS 卷角色（`RoleValue`）→ 名字（app 再本地化）。0 为没有角色（普通卷）。
    static func roleName(_ value: UInt64?) -> String? {
        switch value ?? 0 {
        case 0x0001: "System"
        case 0x0002: "User"
        case 0x0004: "Recovery"
        case 0x0008: "VM"
        case 0x0010: "Preboot"
        case 0x0020: "Installer"
        case 0x0040: "Data"
        case 0x0080: "Baseband"
        case 0x00C0: "Update"
        case 0x0100: "xART"
        case 0x0140: "Hardware"
        case 0x0180: "Backup"
        case 0x01C0: "Sidecar"
        case 0: nil
        default: "Other"
        }
    }

    /// 「用户可见」的角色：有这类卷的容器才是主容量组，其余（Recovery 容器、iSC 预启动容器）是辅助组。
    static let primaryRoles: Set<String?> = [nil, "System", "User", "Data"]

    /// 组归属：向上先遇到 RAID 组归 RAID，先遇到物理盘归那块盘。
    private static func owner(of node: IORegistryObject, snapshot: DiskInventory.Snapshot) -> CapacityOwner? {
        guard let anchor = node.ancestor(conformingTo: ["AppleRAIDSet", "IOBlockStorageDevice"]), let id = anchor.registryID
        else { return nil }
        if anchor.conforms(to: "AppleRAIDSet") { return snapshot.raidKeysByRegistryID[id].map(CapacityOwner.raid) }
        return snapshot.keysByRegistryID[id].map(CapacityOwner.disk)
    }

    static func groups(snapshot: DiskInventory.Snapshot, mounts: [String: Mount], purgeable: UInt64?) -> [CapacityGroup] {
        var groups: [CapacityGroup] = []
        var covered: Set<String> = []
        for container in IORegistryObject.services(matching: "AppleAPFSContainer") {
            guard let media = container.parent, media.conforms(to: "IOMedia"), let owner = owner(of: media, snapshot: snapshot),
                let total = media.uint64("Size")
            else { continue }
            var volumes: [StorageVolume] = []
            var available: UInt64?
            var isBoot = false
            for volume in container.children where volume.conforms(to: "IOMedia") {
                guard let bsd = volume.string("BSD Name") else { continue }
                covered.insert(bsd)
                let mount = mount(of: bsd, in: mounts)
                if let mount {
                    available = available ?? mount.availableBytes
                    if mount.mountPoint == "/" || mount.mountPoint == "/System/Volumes/Data" { isBoot = true }
                }
                volumes.append(
                    StorageVolume(
                        name: volume.string("FullName") ?? bsd, role: roleName(volume.uint64("RoleValue")),
                        mountPoint: mount?.mountPoint, usedBytes: mount.flatMap { spaceUsed(mountPoint: $0.mountPoint) },
                        bsdName: bsd))
            }
            // 没有任何卷挂载：可用空间无从得知，不成组。
            guard let available else { continue }
            let primary = volumes.contains { primaryRoles.contains($0.role) }
            let name =
                volumes.first { $0.role == "System" }?.name ?? volumes.first { $0.role == "Data" }?.name
                ?? volumes.first { $0.role == nil }?.name ?? volumes.first?.name ?? (media.string("BSD Name") ?? "APFS")
            let key = DiskIdentity.key(["group", media.string("UUID") ?? media.string("BSD Name") ?? name])
            groups.append(
                CapacityGroup(
                    key: key, owner: owner, name: name, fileSystem: "apfs", totalBytes: total, availableBytes: available,
                    purgeableBytes: isBoot ? purgeable : nil, volumes: volumes, isBoot: isBoot, isAuxiliary: !primary))
        }
        // 非 APFS 的已挂载分区（exFAT、FAT、HFS+ …）。
        for (bsd, mount) in mounts where mount.fileSystem != "apfs" && !covered.contains(bsd) {
            guard let media = IORegistryObject.media(bsdName: bsd), let owner = owner(of: media, snapshot: snapshot) else { continue }
            let name = mount.mountPoint == "/" ? bsd : (mount.mountPoint as NSString).lastPathComponent
            let key = DiskIdentity.key(["group", media.string("UUID") ?? bsd])
            groups.append(
                CapacityGroup(
                    key: key, owner: owner, name: name, fileSystem: mount.fileSystem, totalBytes: mount.totalBytes,
                    availableBytes: mount.availableBytes, purgeableBytes: nil,
                    volumes: [StorageVolume(name: name, role: nil, mountPoint: mount.mountPoint, usedBytes: mount.totalBytes - min(mount.availableBytes, mount.totalBytes), bsdName: bsd)],
                    isBoot: false, isAuxiliary: false))
        }
        // 主组在前；启动组最先。
        return groups.sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            if a.isAuxiliary != b.isAuxiliary { return !a.isAuxiliary }
            return a.totalBytes > b.totalBytes
        }
    }
}
