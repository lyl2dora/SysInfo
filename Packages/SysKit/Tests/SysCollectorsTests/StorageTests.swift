// 存储模块（存储模块设计 §8，D54、D55）：盘的键、物理盘判定、驱动统计与速率、SMART 解析与合理性、MetricID 解析；
// 硬件测试读真实机器（`make test-hw`），断言只用运行时读到的值，不写死任何机型的盘数或型号（D20）。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

@Suite struct DiskIdentityTests {
    @Test func keyIsTwelveHexAndDependsOnSalt() {
        let saltA = Data(repeating: 1, count: DiskIdentity.saltLength)
        let saltB = Data(repeating: 2, count: DiskIdentity.saltLength)
        let a1 = DiskIdentity.key(["disk", "SERIAL", "MODEL"], salt: saltA)
        let a2 = DiskIdentity.key(["disk", "SERIAL", "MODEL"], salt: saltA)
        let b = DiskIdentity.key(["disk", "SERIAL", "MODEL"], salt: saltB)
        #expect(a1 == a2)
        #expect(a1 != b)
        #expect(a1.rawValue.count == 12)
        #expect(DiskKey(validating: a1.rawValue) == a1)
        // 拼接歧义：["ab", "c"] 与 ["a", "bc"] 不能撞键。
        #expect(DiskIdentity.key(["ab", "c"], salt: saltA) != DiskIdentity.key(["a", "bc"], salt: saltA))
        // 键里看不出序列号。
        #expect(!a1.rawValue.contains("SERIAL"))
    }

    @Test func loadOrCreateSaltPersistsOnce() throws {
        let suite = "zone.lyl.sysinfo.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            // removePersistentDomain 只清空内容，cfprefsd 会留下空的 plist 文件，一并删掉。
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(
                at: URL.libraryDirectory.appending(path: "Preferences/\(suite).plist"))
        }
        let first = DiskIdentity.loadOrCreateSalt(in: defaults)
        let second = DiskIdentity.loadOrCreateSalt(in: defaults)
        #expect(first == second)
        #expect(first.count == DiskIdentity.saltLength)
    }

    @Test func diskKeyValidation() {
        #expect(DiskKey(validating: "0123456789ab") != nil)
        #expect(DiskKey(validating: "0123456789AB")?.rawValue == "0123456789ab")
        #expect(DiskKey(validating: "0123456789a") == nil)
        #expect(DiskKey(validating: "0123456789ag") == nil)
    }
}

@Suite struct StorageMetricIDTests {
    @Test func roundTrip() throws {
        let key = DiskKey(rawValue: "a1b2c3d4e5f6")
        for metric in MetricID.DiskMetric.allCases {
            let id = MetricID.storageDisk(key, metric)
            let parsed = try #require(id.storageDiskMetric)
            #expect(parsed.key == key)
            #expect(parsed.metric == metric)
            #expect(id.storageGroupMetric == nil)
        }
        for metric in MetricID.GroupMetric.allCases {
            let parsed = try #require(MetricID.storageGroup(key, metric).storageGroupMetric)
            #expect(parsed.metric == metric)
        }
        #expect(MetricID("storage.disk.nothex12chars.read").storageDiskMetric == nil)
        #expect(MetricID("storage.disk.a1b2c3d4e5f6.bogus").storageDiskMetric == nil)
        #expect(MetricID.cpuUsageTotal.storageDiskMetric == nil)
    }
}

@Suite struct DiskInventoryParsingTests {
    @Test func physicalInterconnectFiltersVirtualAndFile() {
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal"])?.location == .internal)
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "PCI-Express", "Physical Interconnect Location": "External"])?.location == .external)
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File"]) == nil)
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "Virtual Interface"]) == nil)
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "USB", "Physical Interconnect Location": "File"]) == nil)
        #expect(DiskInventory.physicalInterconnect(nil) == nil)
        // 没有位置字段：Apple Fabric 按内置，其余按外置。
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "Apple Fabric"])?.location == .internal)
        #expect(DiskInventory.physicalInterconnect(["Physical Interconnect": "USB"])?.location == .external)
    }

    @Test func mediumAndBSDOrdering() {
        #expect(DiskInventory.medium("Solid State") == .solidState)
        #expect(DiskInventory.medium("Rotational") == .rotational)
        #expect(DiskInventory.medium(nil) == .unknown)
        #expect(DiskInventory.bsdNumber("disk10") == 10)
        #expect(DiskInventory.bsdNumber("disk6") < DiskInventory.bsdNumber("disk10"))
        #expect(DiskInventory.bsdNumber(nil) == .max)
    }

    @Test func ioCountersParse() throws {
        let stats: [String: Any] = [
            "Bytes (Read)": 1000, "Bytes (Write)": 2000, "Operations (Read)": 10, "Operations (Write)": 20,
            "Total Time (Read)": 5_000_000, "Total Time (Write)": 8_000_000, "Errors (Read)": 1, "Retries (Write)": 2,
        ]
        let c = try #require(DiskInventory.ioCounters(stats))
        #expect(c.bytesRead == 1000)
        #expect(c.writes == 20)
        #expect(c.readErrors == 1)
        #expect(c.writeRetries == 2)
        #expect(c.writeErrors == 0)
        #expect(DiskInventory.ioCounters(["Bytes (Read)": 1]) == nil)
        #expect(DiskInventory.ioCounters(nil) == nil)
    }
}

@Suite struct StorageIORateTests {
    let base = DiskIOCounters(bytesRead: 1_000_000, bytesWritten: 0, reads: 100, writes: 0, readTimeNanos: 0, writeTimeNanos: 0)

    @Test func ratesAndLatency() {
        var now = base
        now.bytesRead += 4_000_000
        now.reads += 40
        now.readTimeNanos += 40 * 250_000  // 每次 0.25 ms
        let r = StorageIOCollector.rates(previous: base, current: now, elapsedNanos: 2_000_000_000)
        #expect(r[.read] == .some(2_000_000))
        #expect(r[.readOps] == .some(20))
        #expect(r[.write] == .some(0))
        #expect(r[.readLatency] == .some(0.00025))
        // 区间里没有写：延迟这一项「没有 IO」，不是复位。
        #expect(r[.writeLatency] == .some(nil))
    }

    @Test func counterResetIsNotClampedToZero() {
        var now = base
        now.bytesRead = 10  // 回退
        let r = StorageIOCollector.rates(previous: base, current: now, elapsedNanos: 1_000_000_000)
        #expect(r[.read] == nil)
        #expect(r[.readOps] == .some(0))
        #expect(StorageIOCollector.rates(previous: base, current: base, elapsedNanos: 0).isEmpty)
    }
}

@Suite struct SMARTParserTests {
    /// 按 NVMe 1.4 布局拼一份 SMART / Health 日志（小端）。
    static func log(
        warning: UInt8 = 0, kelvin: UInt16 = 313, spare: UInt8 = 100, threshold: UInt8 = 10, used: UInt8 = 1,
        unitsWritten: UInt64 = 184_639_698, mediaErrors: UInt64 = 0, poh: UInt64 = 18_766, sensor1: UInt16 = 0
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        func put16(_ v: UInt16, _ o: Int) { b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8(v >> 8) }
        func put64(_ v: UInt64, _ o: Int) { for i in 0..<8 { b[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
        b[0] = warning
        put16(kelvin, 1)
        b[3] = spare
        b[4] = threshold
        b[5] = used
        put64(336_140_606, 32)
        put64(unitsWritten, 48)
        put64(2_854_098_990, 64)
        put64(462, 96)
        put64(180, 112)
        put64(poh, 128)
        put64(75, 144)
        put64(mediaErrors, 160)
        b[192] = 132  // 超警告温度 132 分钟
        put16(sensor1, 200)
        return b
    }

    @Test func parsesHealthLog() throws {
        let r = try #require(SMARTParser.healthLog(Self.log()))
        #expect(r.criticalWarning.isEmpty)
        #expect(r.temperatureCelsius == 40)
        #expect(r.availableSpare == 100)
        #expect(r.availableSpareThreshold == 10)
        #expect(r.percentageUsed == 1)
        #expect(r.dataUnitsWritten == 184_639_698)
        #expect(r.bytesWritten == 184_639_698 * 512_000)
        #expect(r.hostReadCommands == 2_854_098_990)
        #expect(r.controllerBusyMinutes == 462)
        #expect(r.powerOnHours == 18_766)
        #expect(r.unsafeShutdowns == 75)
        #expect(r.warningTemperatureMinutes == 132)
        #expect(r.temperatureSensors.allSatisfy { $0 == nil })  // 不支持的传感器为 0 → nil
        #expect(r.healthIssues.isEmpty)
        #expect(SMARTParser.healthLog([UInt8](repeating: 0, count: 100)) == nil)
    }

    @Test func highCountersUseUpper64Bits() throws {
        var b = Self.log()
        b[48 + 8] = 1  // 写入量的高 8 字节 = 1
        let r = try #require(SMARTParser.healthLog(b))
        #expect(r.dataUnitsWritten == 184_639_698 + 18_446_744_073_709_551_616.0)
    }

    @Test func healthIssues() throws {
        let warn = try #require(SMARTParser.healthLog(Self.log(warning: 0b0000_0101, spare: 5, threshold: 10, mediaErrors: 3)))
        #expect(warn.criticalWarning.contains(.spareBelowThreshold))
        #expect(warn.criticalWarning.contains(.reliabilityDegraded))
        #expect(warn.healthIssues.count == 3)
        // Apple 的阈值是 99：100 ≥ 99 不算低于阈值。
        let apple = try #require(SMARTParser.healthLog(Self.log(spare: 100, threshold: 99)))
        #expect(apple.healthIssues.isEmpty)
    }

    @Test func identifyAndAppleFlags() throws {
        var r = try #require(SMARTParser.healthLog(Self.log(poh: 32)))
        var identify = [UInt8](repeating: 0, count: 4096)
        identify[0] = 0x6B
        identify[1] = 0x10  // VID 0x106B
        SMARTParser.applyIdentify(identify, to: &r)
        #expect(r.vendorID == 0x106B)
        #expect(r.powerOnHoursUnreliable)
        #expect(r.warningThresholdCelsius == nil)
        #expect(r.nvmeVersion == 0)
        // Intel：VID 0x8086、版本 1.4、阈值 70 / 80 °C。
        identify[0] = 0x86
        identify[1] = 0x80
        identify[80] = 0x00
        identify[81] = 0x04
        identify[82] = 0x01
        identify[266] = UInt8((343 as UInt16) & 0xFF)
        identify[267] = UInt8(343 >> 8)
        identify[268] = UInt8((353 as UInt16) & 0xFF)
        identify[269] = UInt8(353 >> 8)
        SMARTParser.applyIdentify(identify, to: &r)
        #expect(r.vendorID == 0x8086)
        #expect(!r.powerOnHoursUnreliable)
        #expect(r.nvmeVersion == 0x10400)
        #expect(r.warningThresholdCelsius == 70)
        #expect(r.criticalThresholdCelsius == 80)
    }

    @Test func implausibleReadings() throws {
        #expect(SMARTCollector.implausibility(try #require(SMARTParser.healthLog(Self.log()))) == nil)
        #expect(SMARTCollector.implausibility(try #require(SMARTParser.healthLog(Self.log(kelvin: 273 + 150)))) != nil)
        #expect(SMARTCollector.implausibility(try #require(SMARTParser.healthLog(Self.log(spare: 180)))) != nil)
    }

    @Test func samplesCarryKeyAndUnits() throws {
        let key = DiskKey(rawValue: "a1b2c3d4e5f6")
        let r = try #require(SMARTParser.healthLog(Self.log(used: 7)))
        let samples = SMARTCollector.samples(r, key: key, at: SampleTime(monotonicNanos: 1, wallClock: Date()))
        let byID = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
        #expect(byID[.storageDisk(key, .temp)]?.value == 40)
        #expect(byID[.storageDisk(key, .life)]?.value == 0.07)
        #expect(byID[.storageDisk(key, .spare)]?.value == 1)
        #expect(byID[.storageDisk(key, .dataWritten)]?.value == r.bytesWritten)
    }
}

@Suite struct StorageCapacityParsingTests {
    @Test func apfsRoles() {
        #expect(StorageCapacityCollector.roleName(0) == nil)
        #expect(StorageCapacityCollector.roleName(nil) == nil)
        #expect(StorageCapacityCollector.roleName(0x0001) == "System")
        #expect(StorageCapacityCollector.roleName(0x0040) == "Data")
        #expect(StorageCapacityCollector.roleName(0x0010) == "Preboot")
        #expect(StorageCapacityCollector.roleName(0x00C0) == "Update")
        #expect(StorageCapacityCollector.roleName(0x9999) == "Other")
        #expect(StorageCapacityCollector.primaryRoles.contains("Data"))
        #expect(!StorageCapacityCollector.primaryRoles.contains("Recovery"))
    }

    @Test func snapshotMountMapping() {
        let mounts: [String: StorageCapacityCollector.Mount] = [
            "disk3s1s1": .init(bsdName: "disk3s1s1", mountPoint: "/", fileSystem: "apfs", totalBytes: 10, availableBytes: 5),
            "disk3s5": .init(bsdName: "disk3s5", mountPoint: "/System/Volumes/Data", fileSystem: "apfs", totalBytes: 10, availableBytes: 5),
        ]
        #expect(StorageCapacityCollector.mount(of: "disk3s1", in: mounts)?.mountPoint == "/")
        #expect(StorageCapacityCollector.mount(of: "disk3s5", in: mounts)?.mountPoint == "/System/Volumes/Data")
        #expect(StorageCapacityCollector.mount(of: "disk3s2", in: mounts) == nil)
    }

    @Test func throttleDriverParsing() {
        #expect(NVMeThrottleReader.registryID(in: "IONVMeBlockStorageDevice <id 0x100000ece>") == 0x100000ece)
        #expect(NVMeThrottleReader.registryID(in: "NS_01") == nil)
        #expect(NVMeThrottleReader.driverClass("IONVMeBlockStorageDevice <id 0x100000ece>") == "IONVMeBlockStorageDevice")
    }
}

/// 串行：NVMe SMART 的用户态连接是独占的（D56），同一套件里的几个测试并行读同一块盘时会互相拿到
/// kIOReturnExclusiveAccess，偶发失败（2026-10-17 实测单独跑这一套件约一半次数失败）。
@Suite(.tags(.hardware), .hardwareOnly, .serialized)
struct StorageHardwareTests {
    @Test func findsPhysicalDisksWithStatistics() throws {
        let io = StorageIOCollector()
        let result = io.selfTest()
        #expect(result.isUsable)
        let inventory = DiskInventory.shared.inventory
        #expect(!inventory.disks.isEmpty)
        // 每台目标机都有一块内置盘（D28：都是带内置 SSD 的 Mac）。
        #expect(inventory.disks.contains { $0.location == .internal })
        for disk in inventory.disks {
            #expect(disk.bsdName?.hasPrefix("disk") == true)
            #expect((disk.sizeBytes ?? 0) > 0)
        }
        // RAID 成员都属于清单里的阵列，成员数一致。
        for set in inventory.raidSets {
            #expect(set.members.allSatisfy { inventory.disk($0)?.raid?.setKey == set.key })
        }
        _ = io.sample(at: .now())
        usleep(200_000)
        let samples = io.sample(at: .now()).samples
        #expect(samples.contains { $0.id.storageDiskMetric?.metric == .read && $0.value != nil })
    }

    @Test func internalSMARTIsPlausible() throws {
        let smart = SMARTCollector()
        let result = smart.selfTest()
        #expect(result.isUsable)
        let inventory = DiskInventory.shared.inventory
        let internalDisk = try #require(inventory.disks.first { $0.location == .internal && $0.smartCapable })
        let record = try #require(smart.latestRecords[internalDisk.key])
        #expect(record.temperatureCelsius > 0 && record.temperatureCelsius < 100)
        #expect(record.percentageUsed <= 100)
        #expect(record.dataUnitsWritten > 0)
        #expect(SMARTCollector.implausibility(record) == nil)
    }

    @Test func focusLimitsReadsToFocusedDisks() throws {
        let smart = SMARTCollector()
        _ = smart.selfTest()
        let inventory = DiskInventory.shared.inventory
        let primary = try #require(inventory.primaryDisk)
        // 先读一轮全部盘，记下这一轮读到了哪些（并行的其他测试可能正占着某块盘的 SMART 连接，D56）。
        smart.setFocus(nil)
        let readAll = Set(smart.sample(at: .now()).samples.compactMap { $0.id.storageDiskMetric?.key })
        #expect(readAll.contains(primary.key))
        // 焦点只有主盘：刚读过的其他盘在 55 s 内不再读；没读到的盘（被占用）允许补读。
        smart.setFocus([primary.key])
        let keys = Set(smart.sample(at: .now()).samples.compactMap { $0.id.storageDiskMetric?.key })
        let allowed = Set([primary.key]).union(Set(inventory.disks.map(\.key)).subtracting(readAll))
        #expect(keys.isSubset(of: allowed))
        #expect(keys.contains(primary.key))
    }

    @Test func capacityGroupsFitInsideDisks() throws {
        let capacity = StorageCapacityCollector()
        #expect(capacity.selfTest().isUsable)
        let groups = capacity.latestGroups
        #expect(groups.contains { $0.isBoot })
        let inventory = DiskInventory.shared.inventory
        for group in groups {
            #expect(group.availableBytes <= group.totalBytes)
            if case .disk(let key) = group.owner, let size = inventory.disk(key)?.sizeBytes {
                #expect(group.totalBytes <= size)
            }
        }
    }
}
