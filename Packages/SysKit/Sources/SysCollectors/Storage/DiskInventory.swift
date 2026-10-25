// 物理盘清单（存储模块设计 §4.1，D54）：三个存储采集器共用一份。
//
// - 物理盘 = `IOBlockStorageDevice` 中 Physical Interconnect 不是 Virtual Interface、位置不是 File 的（磁盘映像、
//   模拟器 cryptex 都是 Virtual Interface / File）。RAID 虚拟盘不在 `IOBlockStorageDevice` 下，天然不算；
// - RAID 关系读 IORegistry 的 `AppleRAIDMember` / `AppleRAIDSet`（`AppleRAID-*` 属性），不 spawn `diskutil`；
// - 盘插拔：IOKit 匹配通知（发布 / 终止）在私有队列上把「脏」标记置位，下一次取快照时重新枚举；
//   之后 10 s 内每次取快照都再枚举（最多每秒一次），等驱动与介质挂上；
//   RAID 与卷的状态变化没有通知，由容量采集器每次取快照时强制刷新（最多 60 s 一次）；
// - 只用公开 IOKit 接口。

import Foundation
import IOKit
import os
import Synchronization
import SysModel

public final class DiskInventory: Sendable {
    /// app 与 CLI 共用的实例：三个存储采集器拿同一份清单。
    public static let shared = DiskInventory()

    /// 一块物理盘在 IORegistry 里的句柄（SMART 与 Statistics 要用）。
    struct Entry: Sendable {
        var key: DiskKey
        var device: IORegistryObject
        /// `IOBlockStorageDriver`（Statistics 在它上面）。
        var driver: IORegistryObject?
        var registryID: UInt64?
    }

    /// 一次枚举的结果。
    struct Snapshot: Sendable {
        var inventory: StorageInventory
        var entries: [DiskKey: Entry]
        /// registry entry ID → 盘键（容量组向上找归属时用）。
        var keysByRegistryID: [UInt64: DiskKey]
        /// RAID 组：阵列对象的 registry entry ID → 组键。
        var raidKeysByRegistryID: [UInt64: DiskKey]
    }

    private struct State {
        var snapshot: Snapshot?
        var dirty = true
        /// 每次置脏加一：枚举期间又来了通知时，枚举完不清脏标记（审计 A42）。
        var dirtySerial: UInt64 = 0
        /// 插拔通知之后的这段时间里每次取快照都重新枚举（最多每秒一次）：首次匹配时 driver、整盘 IOMedia
        /// 可能还没挂上，之后挂上不会再来通知。
        var settleUntil: ContinuousClock.Instant?
        var generation: UInt64 = 0
        var notificationsInstalled = false
        var lastEnumeration: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let notificationQueue = DispatchQueue(label: "zone.lyl.sysinfo.storage.inventory", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sysinfo-cli", category: "storage")

    public init() {}

    /// 最近一次枚举出的清单（不触发枚举）。
    public var inventory: StorageInventory { state.withLock { $0.snapshot?.inventory ?? .empty } }

    /// registry entry ID → 盘键（IOReport 通道的驱动名里带 registry ID，诊断页据此对应到盘）。
    public func diskKey(registryID: UInt64) -> DiskKey? {
        state.withLock { $0.snapshot?.keysByRegistryID[registryID] }
    }

    /// 让下一次取快照时重新枚举（自检、唤醒）。
    public func invalidate() {
        state.withLock {
            $0.dirty = true
            $0.dirtySerial &+= 1
        }
    }

    /// 插拔后驱动与介质陆续挂上的时间窗。
    static let settleSeconds: Int64 = 10

    /// 插拔通知：置脏，并在之后的 `settleSeconds` 里持续重新枚举。
    func noteDeviceChange() {
        let until = ContinuousClock.now + .seconds(Self.settleSeconds)
        state.withLock {
            $0.dirty = true
            $0.dirtySerial &+= 1
            $0.settleUntil = until
        }
    }

    /// 当前快照：脏了或 `refresh` 时重新枚举。同一秒内的重复刷新合并成一次（三个采集器在同一个 tick 里都要取）。
    func snapshot(refresh: Bool = false) -> Snapshot {
        installNotificationsIfNeeded()
        let now = ContinuousClock.now
        let (cached, serial): (Snapshot?, UInt64) = state.withLock { s in
            guard let snapshot = s.snapshot, !s.dirty else { return (nil, s.dirtySerial) }
            let settling = s.settleUntil.map { now < $0 } ?? false
            if refresh || settling, let last = s.lastEnumeration, now - last >= .seconds(1) { return (nil, s.dirtySerial) }
            return (snapshot, s.dirtySerial)
        }
        if let cached { return cached }
        let fresh = Self.enumerate()
        let (snapshot, changed) = state.withLock { s -> (Snapshot, Bool) in
            let changed = s.snapshot.map {
                $0.inventory.disks != fresh.disks || $0.inventory.raidSets != fresh.raidSets
            } ?? true
            if changed { s.generation &+= 1 }
            var snapshot = fresh.snapshot
            snapshot.inventory.generation = s.generation
            s.snapshot = snapshot
            if s.dirtySerial == serial { s.dirty = false }
            s.lastEnumeration = now
            return (snapshot, changed)
        }
        if changed {
            let disks = snapshot.inventory.disks.count
            let sets = snapshot.inventory.raidSets.count
            let generation = snapshot.inventory.generation
            logger.info("物理盘清单更新：\(disks) 块盘，\(sets) 个 RAID 组（第 \(generation) 代）")
        }
        return snapshot
    }

    // MARK: - 插拔通知

    private func installNotificationsIfNeeded() {
        let install = state.withLock { s -> Bool in
            guard !s.notificationsInstalled else { return false }
            s.notificationsInstalled = true
            return true
        }
        guard install, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, notificationQueue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            _ = IORegistryObject.drain(iterator)  // 必须取空，否则不再通知
            guard let refcon else { return }
            Unmanaged<DiskInventory>.fromOpaque(refcon).takeUnretainedValue().noteDeviceChange()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOBlockStorageDevice"), callback, refcon, &iterator)
                == KERN_SUCCESS
            {
                _ = IORegistryObject.drain(iterator)  // 首次取空：现有的盘不算变化；迭代器留着接收后续通知
            }
        }
        // 端口与迭代器随进程存在（shared 实例不释放）。
    }

    // MARK: - 枚举

    struct Enumeration {
        var disks: [PhysicalDisk]
        var raidSets: [RAIDSet]
        var snapshot: Snapshot
    }

    /// 物理盘判定（纯函数，便于单测）：返回接口名与位置；不是物理盘时返回 nil。
    static func physicalInterconnect(_ protocolCharacteristics: [String: Any]?) -> (interconnect: String, location: DiskLocation)? {
        guard let interconnect = protocolCharacteristics?["Physical Interconnect"] as? String, !interconnect.isEmpty,
            interconnect != "Virtual Interface"
        else { return nil }
        let location = protocolCharacteristics?["Physical Interconnect Location"] as? String
        switch location {
        case "File": return nil
        case "Internal": return (interconnect, .internal)
        case "External": return (interconnect, .external)
        default:
            // 没有位置字段（少数桥接盘）：Apple Fabric 一定是内置，其余按外置。
            return (interconnect, interconnect == "Apple Fabric" ? .internal : .external)
        }
    }

    static func medium(_ value: String?) -> DiskMedium {
        switch value {
        case "Solid State": .solidState
        case "Rotational": .rotational
        default: .unknown
        }
    }

    /// 一次枚举里重复出现的键，全部换成各自的路径键；不重复的保持原样（纯函数，便于单测；D104）。
    static func disambiguatedKeys(_ keys: [DiskKey], pathKeys: [DiskKey]) -> [DiskKey] {
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        return zip(keys, pathKeys).map { key, pathKey in counts[key, default: 0] > 1 ? pathKey : key }
    }

    /// BSD 名里的数字（排序用）：disk10 → 10。
    static func bsdNumber(_ name: String?) -> Int {
        guard let name, name.hasPrefix("disk") else { return .max }
        return Int(name.dropFirst(4).prefix { $0.isNumber }) ?? .max
    }

    private struct MemberInfo {
        var memberUUID: String
        var setUUID: String
        var status: String
    }

    static func enumerate() -> Enumeration {
        var disks: [(disk: PhysicalDisk, entry: Entry, member: MemberInfo?)] = []
        var pathKeys: [DiskKey] = []
        for device in IORegistryObject.services(matching: "IOBlockStorageDevice") {
            guard let (interconnect, location) = physicalInterconnect(device.dictionary("Protocol Characteristics")) else {
                continue
            }
            let characteristics = device.dictionary("Device Characteristics") ?? [:]
            let model = (characteristics["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let serial = (characteristics["Serial Number"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let firmware = (characteristics["Product Revision Level"] as? String)?.trimmingCharacters(in: .whitespaces)
            let path = IORegistryEntryCopyPath(device.entry, kIOServicePlane)?.takeRetainedValue() as String? ?? ""
            let pathKey = DiskIdentity.key(["path", path])
            let key = serial.isEmpty ? pathKey : DiskIdentity.key(["disk", serial, model])
            var driver: IORegistryObject?
            var whole: IORegistryObject?
            var member: MemberInfo?
            for node in device.descendants {
                if driver == nil, node.conforms(to: "IOBlockStorageDriver") {
                    driver = node
                } else if whole == nil, node.conforms(to: "IOMedia"), node.bool("Whole") == true {
                    whole = node
                } else if member == nil, node.conforms(to: "AppleRAIDMember"),
                    let memberUUID = node.string("AppleRAID-MemberUUID"), let setUUID = node.string("AppleRAID-SetUUID")
                {
                    member = MemberInfo(memberUUID: memberUUID, setUUID: setUUID, status: node.string("AppleRAID-MemberStatus") ?? "")
                }
            }
            let disk = PhysicalDisk(
                key: key, model: model.isEmpty ? "Unknown" : model, firmware: firmware?.isEmpty == true ? nil : firmware,
                location: location, interconnect: interconnect, bsdName: whole?.string("BSD Name"),
                sizeBytes: whole?.uint64("Size"), blockSize: whole?.uint64("Preferred Block Size"),
                medium: medium(characteristics["Medium Type"] as? String),
                smartCapable: device.bool("NVMe SMART Capable") ?? false, raid: nil)
            disks.append((disk, Entry(key: key, device: device, driver: driver, registryID: device.registryID), member))
            pathKeys.append(pathKey)
        }
        // 同款 USB 桥报同一个假序列号：键重复的盘改用 IOService 路径作键（D104）。
        for (i, key) in Self.disambiguatedKeys(disks.map(\.disk.key), pathKeys: pathKeys).enumerated() {
            disks[i].disk.key = key
            disks[i].entry.key = key
        }

        // RAID 组：成员序号按阵列的 AppleRAID-Members 顺序。
        var raidSets: [RAIDSet] = []
        var raidKeysByRegistryID: [UInt64: DiskKey] = [:]
        for set in IORegistryObject.services(matching: "AppleRAIDSet") {
            guard let setUUID = set.string("AppleRAID-SetUUID") else { continue }
            let key = DiskIdentity.key(["raid", setUUID])
            let memberUUIDs = set.property("AppleRAID-Members") as? [String] ?? []
            let media = set.children.first { $0.conforms(to: "IOMedia") }
            var members: [DiskKey] = []
            for (index, uuid) in memberUUIDs.enumerated() {
                guard let i = disks.firstIndex(where: { $0.member?.memberUUID == uuid }) else { continue }
                disks[i].disk.raid = RAIDMembership(setKey: key, index: index, status: disks[i].member?.status ?? "")
                members.append(disks[i].disk.key)
            }
            // 阵列里找不到成员 UUID 的盘（成员掉线后阵列列表可能变化）：仍按 SetUUID 归组，序号未知。
            for i in disks.indices where disks[i].disk.raid == nil && disks[i].member?.setUUID == setUUID {
                disks[i].disk.raid = RAIDMembership(setKey: key, index: nil, status: disks[i].member?.status ?? "")
                members.append(disks[i].disk.key)
            }
            raidSets.append(
                RAIDSet(
                    key: key, name: set.string("AppleRAID-SetName") ?? "RAID", level: set.string("AppleRAID-LevelName") ?? "",
                    status: set.string("AppleRAID-SetStatus") ?? "", sizeBytes: media?.uint64("Size"),
                    bsdName: media?.string("BSD Name"), members: members))
            if let id = set.registryID { raidKeysByRegistryID[id] = key }
        }
        // 成员在但阵列对象没有出现（阵列离线）：仍标出 RAID 关系，组状态未知。
        for i in disks.indices where disks[i].disk.raid == nil {
            guard let member = disks[i].member else { continue }
            let key = DiskIdentity.key(["raid", member.setUUID])
            disks[i].disk.raid = RAIDMembership(setKey: key, index: nil, status: member.status)
            if let s = raidSets.firstIndex(where: { $0.key == key }) {
                raidSets[s].members.append(disks[i].disk.key)
            } else {
                raidSets.append(
                    RAIDSet(key: key, name: "RAID", level: "", status: "Offline", sizeBytes: nil, bsdName: nil, members: [disks[i].disk.key]))
            }
        }

        disks.sort { a, b in
            if (a.disk.location == .internal) != (b.disk.location == .internal) { return a.disk.location == .internal }
            return bsdNumber(a.disk.bsdName) < bsdNumber(b.disk.bsdName)
        }
        raidSets.sort { bsdNumber($0.bsdName) < bsdNumber($1.bsdName) }
        let physical = disks.map(\.disk)
        var entries: [DiskKey: Entry] = [:]
        var keysByRegistryID: [UInt64: DiskKey] = [:]
        for item in disks {
            entries[item.disk.key] = item.entry
            if let id = item.entry.registryID { keysByRegistryID[id] = item.disk.key }
        }
        let inventory = StorageInventory(disks: physical, raidSets: raidSets, generation: 0)
        return Enumeration(
            disks: physical, raidSets: raidSets,
            snapshot: Snapshot(
                inventory: inventory, entries: entries, keysByRegistryID: keysByRegistryID,
                raidKeysByRegistryID: raidKeysByRegistryID))
    }

    // MARK: - Statistics

    /// 驱动 Statistics 字典 → 计数（纯函数，便于单测）。缺少读写字节或次数时返回 nil。
    static func ioCounters(_ statistics: [String: Any]?) -> DiskIOCounters? {
        guard let s = statistics else { return nil }
        func value(_ key: String) -> UInt64? { (s[key] as? NSNumber)?.uint64Value }
        guard let bytesRead = value("Bytes (Read)"), let bytesWritten = value("Bytes (Write)"),
            let reads = value("Operations (Read)"), let writes = value("Operations (Write)")
        else { return nil }
        return DiskIOCounters(
            bytesRead: bytesRead, bytesWritten: bytesWritten, reads: reads, writes: writes,
            readTimeNanos: value("Total Time (Read)") ?? 0, writeTimeNanos: value("Total Time (Write)") ?? 0,
            readErrors: value("Errors (Read)") ?? 0, writeErrors: value("Errors (Write)") ?? 0,
            readRetries: value("Retries (Read)") ?? 0, writeRetries: value("Retries (Write)") ?? 0)
    }

    static func readCounters(_ entry: Entry) -> DiskIOCounters? {
        ioCounters(entry.driver?.dictionary("Statistics"))
    }
}
