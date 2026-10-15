// 存储指标的入库规则与导出标签（存储模块设计 §3.1、§5）。

import SysCollectors
import SysModel
import Testing
@testable import SysStore

@Suite struct StorageHistoryTests {
    let key = DiskKey(rawValue: "a1b2c3d4e5f6")

    @Test func storageMetricsBelongToStorageModule() throws {
        let read = try #require(HistoryCatalog.spec(for: .storageDisk(key, .read)))
        #expect(read.module == .storage)
        #expect(read.aggregation == .interval)
        #expect(read.unit == "B/s")
        #expect(read.collector == StorageIOCollector.collectorID)
        let temp = try #require(HistoryCatalog.spec(for: .storageDisk(key, .temp)))
        #expect(temp.aggregation == .instant)
        #expect(temp.unit == "degC")
        #expect(temp.collector == SMARTCollector.collectorID)
        #expect(HistoryCatalog.spec(for: .storageDisk(key, .life))?.unit == "ratio")
        #expect(HistoryCatalog.spec(for: .storageDisk(key, .dataWritten))?.unit == "B")
        #expect(HistoryCatalog.spec(for: .storageDisk(key, .mediaErrors))?.unit == "count")
        let used = try #require(HistoryCatalog.spec(for: .storageGroup(key, .used)))
        #expect(used.collector == StorageCapacityCollector.collectorID)
        #expect(used.module == .storage)
    }

    @Test func panelOnlyMetricsAreNotRecorded() {
        for metric in [MetricID.DiskMetric.readOps, .writeOps, .readLatency, .writeLatency, .warning] {
            #expect(HistoryCatalog.spec(for: .storageDisk(key, metric)) == nil)
        }
        #expect(HistoryCatalog.spec(for: .storageGroup(key, .total)) == nil)
    }

    @Test func labelsUseModelAndPositionWithoutSerials() {
        let setKey = DiskKey(rawValue: "ffffffffffff")
        let internalDisk = PhysicalDisk(
            key: DiskKey(rawValue: "000000000001"), model: "APPLE SSD AP1024Z", firmware: nil, location: .internal,
            interconnect: "Apple Fabric", bsdName: "disk0", sizeBytes: 1, blockSize: 4096, medium: .solidState,
            smartCapable: true, raid: nil)
        let member = PhysicalDisk(
            key: DiskKey(rawValue: "000000000002"), model: "INTEL SSDPF2NV153TZ", firmware: nil, location: .external,
            interconnect: "PCI-Express", bsdName: "disk6", sizeBytes: 1, blockSize: 512, medium: .solidState,
            smartCapable: true, raid: RAIDMembership(setKey: setKey, index: 2, status: "Online"))
        let external = PhysicalDisk(
            key: DiskKey(rawValue: "000000000003"), model: "USB Disk", firmware: nil, location: .external,
            interconnect: "USB", bsdName: "disk9", sizeBytes: 1, blockSize: 512, medium: .unknown, smartCapable: false,
            raid: nil)
        let inventory = StorageInventory(
            disks: [internalDisk, member, external],
            raidSets: [RAIDSet(key: setKey, name: "Media", level: "Stripe", status: "Online", sizeBytes: 1, bsdName: "disk11", members: [member.key])],
            generation: 1)
        let labels = StorageLabels.labels(inventory: inventory, groups: [])
        #expect(labels[internalDisk.key.rawValue] == "APPLE SSD AP1024Z · internal")
        #expect(labels[member.key.rawValue] == "INTEL SSDPF2NV153TZ · RAID Media member 3")
        #expect(labels[external.key.rawValue] == "USB Disk · external 1")
        #expect(labels[setKey.rawValue] == "RAID Media (Stripe)")
    }
}
