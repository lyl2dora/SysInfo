// 内存模块（内存模块设计 §9，D49）：活动监视器口径、速率与复位、陈旧判定、带宽直方图；
// 硬件测试读真实机器（`make test-hw`），断言只用运行时读到的值，不写死任何机型的内存大小（D20）。

import Darwin
import Foundation
import SysModel
import Testing
@testable import SysCollectors

@Suite struct MemoryMathTests {
    func counts(compressor: UInt64? = 1000, fallback: UInt64? = nil) -> MemoryCounts {
        MemoryCounts(
            pageSize: 16384, physicalBytes: 64 << 30, usableBytes: 63 << 30, free: 100_000, internalPages: 2_000_000,
            externalPages: 1_300_000, purgeable: 50_000, wired: 200_000, compressorPages: compressor,
            compressedBytesFallback: fallback, uncompressedPagesInCompressor: compressor.map { $0 * 3 })
    }

    @Test func activityMonitorFormula() {
        let c = counts()
        #expect(c.appBytes == Double(2_000_000 - 50_000) * 16384)
        #expect(c.wiredBytes == 200_000 * 16384)
        #expect(c.compressedBytes?.value == 16_384_000.0)
        #expect(c.compressedBytes?.estimated == false)
        #expect(c.usedBytes == Double(1_950_000 + 200_000 + 1000) * 16384)
        // 已缓存 = external + purgeable；空闲只取 free（external 已含 speculative）。
        #expect(c.cachedBytes == Double(1_350_000) * 16384)
        #expect(c.freeBytes == 100_000 * 16384)
        #expect(c.queueSumBytes == Double(100_000 + 2_000_000 + 1_300_000 + 200_000 + 1000) * 16384)
        #expect(c.compressionRatio == 3)
    }

    @Test func compressedFallsBackToBytesUsedAsEstimate() {
        let c = counts(compressor: nil, fallback: 12_345_678)
        #expect(c.compressedBytes?.value == 12_345_678)
        #expect(c.compressedBytes?.estimated == true)
        #expect(c.compressionRatio == nil)
    }

    @Test func noCompressedPagesHasNoRatio() {
        #expect(counts(compressor: 0).compressionRatio == nil)
    }

    @Test func purgeableLargerThanInternalClampsAppToZero() {
        var c = counts()
        c.purgeable = c.internalPages + 1
        #expect(c.appBytes == 0)
    }

    @Test func ratesAndCounterReset() {
        let a = MemoryEventCounts(pageins: 100, pageouts: 10, swapins: 0, swapouts: 0, compressions: 500, decompressions: 400)
        var b = a
        b.pageins = 300
        b.compressions = 1500
        b.decompressions = 300  // 回退：按复位处理
        let rates = MemoryEventCounts.rates(previous: a, current: b, elapsedNanos: 2_000_000_000)
        #expect(rates[.memoryPageInRate] == .some(100))
        #expect(rates[.memoryCompressionRate] == .some(500))
        #expect(rates[.memoryPageOutRate] == .some(0))
        #expect(rates[.memoryDecompressionRate] == .some(nil))
        #expect(MemoryEventCounts.rates(previous: a, current: b, elapsedNanos: 0).isEmpty)
    }

    @Test func identicalStatisticsAreStale() {
        var raw = vm_statistics64_data_t()
        raw.pageins = 5
        let a = VMStatistics(raw: raw, count: MemoryCollector.vmInfo64Count)
        var changed = raw
        changed.faults = 1
        #expect(a.isIdentical(to: VMStatistics(raw: raw, count: MemoryCollector.vmInfo64Count)))
        #expect(!a.isIdentical(to: VMStatistics(raw: changed, count: MemoryCollector.vmInfo64Count)))
    }

    @Test func rev6CountIs104() {
        #expect(MemoryCollector.vmInfo64Count == 104)
    }

    @Test func pressureLevelDecoding() {
        #expect(MemoryPressureLevel(sampleValue: 1) == .normal)
        #expect(MemoryPressureLevel(sampleValue: 4) == .critical)
        #expect(MemoryPressureLevel(sampleValue: 3) == nil)
        #expect(MemoryPressureLevel.warning > .normal)
    }
}

@Suite struct BandwidthHistogramTests {
    @Test func parsesStateNames() throws {
        let h = try #require(BandwidthHistogram(stateNames: ["16GB/s", "32GB/s", "48GB/s"]))
        #expect(h.upperBounds == [16e9, 32e9, 48e9])
        #expect(h.midpoints == [8e9, 24e9, 40e9])
        #expect(BandwidthHistogram(stateNames: ["800MB/s", "1.6GB/s"])?.upperBounds == [800e6, 1.6e9])
    }

    @Test func rejectsUnknownOrUnorderedNames() {
        #expect(BandwidthHistogram(stateNames: []) == nil)
        #expect(BandwidthHistogram(stateNames: ["IDLE", "16GB/s"]) == nil)
        #expect(BandwidthHistogram(stateNames: ["32GB/s", "16GB/s"]) == nil)
    }

    @Test func weightedMean() throws {
        let h = try #require(BandwidthHistogram(stateNames: ["16GB/s", "32GB/s", "48GB/s"]))
        #expect(h.mean(counts: [3, 0, 1]) == (3 * 8e9 + 40e9) / 4)
        #expect(h.mean(counts: [0, 0, 0]) == nil)
        #expect(h.mean(counts: [1, 2]) == nil)  // 通道的档数变了：不硬算
    }
}

@Suite(.tags(.hardware), .hardwareOnly)
struct MemoryHardwareTests {
    @Test func selfTestPassesAndSampleIsConsistent() throws {
        let collector = MemoryCollector()
        let result = collector.selfTest()
        #expect(result.isUsable, "\(result.checks)")
        _ = collector.sample(at: .now())
        usleep(1_100_000)
        let output = collector.sample(at: .now())
        let byID = Dictionary(output.samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let physical = try #require(byID[.memoryPhysical]?.value)
        #expect(physical == Double(try #require(MemoryCollector.sysctlUInt64("hw.memsize"))))
        let used = try #require(byID[.memoryUsed]?.value)
        let app = try #require(byID[.memoryApp]?.value)
        let wired = try #require(byID[.memoryWired]?.value)
        let compressed = try #require(byID[.memoryCompressed]?.value)
        #expect(abs(used - (app + wired + compressed)) < 1)
        #expect(used > 0 && used < physical)
        let usage = try #require(byID[.memoryUsage]?.value)
        #expect(abs(usage - used / physical) < 1e-9)
        let pressure = try #require(byID[.memoryPressure]?.value)
        #expect((0...1).contains(pressure))
        #expect(MemoryPressureLevel(sampleValue: byID[.memoryPressureLevel]?.value) != nil)
        // 页面队列之和与 hw.memsize_usable 相差不超过 3%（自检的提示项）。
        let ratio = try #require(collector.queueSumRatio)
        #expect(abs(ratio - 1) < MemoryCollector.queueSumTolerance)
    }

    @Test func coalitionFootprintsCoverOwnProcess() throws {
        let sampler = AppSampler()
        try #require(sampler.selfTest().isUsable)
        _ = sampler.sample(at: .now())
        let footprints = try #require(sampler.latestFootprints)
        #expect(!footprints.coalitions.isEmpty)
        #expect(zip(footprints.coalitions, footprints.coalitions.dropFirst()).allSatisfy { $0.bytes >= $1.bytes })
        let rows = TopNBuilder().buildMemory(footprints: footprints, rows: 5, grouping: .byApp)
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { ($0.footprint ?? 0) > 0 })
    }

    @Test func bandwidthChannelsAreDiscovered() throws {
        let collector = DRAMBandwidthCollector()
        #expect(collector.selfTest().isUsable)
        _ = collector.sample(at: .now())
        usleep(500_000)
        let output = collector.sample(at: .now())
        #expect(collector.group != nil)
        #expect(output.status == .ok)
        let read = try #require(output.samples.first { $0.id == .memoryBandwidthRead })
        #expect(read.quality == .relative)
    }
}
