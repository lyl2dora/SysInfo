// 功耗与散热（功耗与散热模块设计 §9）：遥测换算与漏记、风扇键发现、热点学习、PMGR 命名、占位值、账本核对、档案 system 段。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

private func reading(_ energyMilliJ: Int64, _ count: Int64, wall: Int64 = 0, at seconds: Double) -> PowerTelemetryReading {
    PowerTelemetryReading(
        accumulatedSystemPowerIn: energyMilliJ, accumulatorCount: count, accumulatedWallEnergy: wall,
        wallClock: Date(timeIntervalSince1970: seconds))
}

@Suite struct TelemetryTests {
    @Test func meanAndWallWatts() throws {
        // 60 次计数、420 J（7 W）；墙插 150 000 µWh × 3.6 / 1000 = 540 J（9 W）
        let a = reading(1_000_000, 100, wall: 1_000_000, at: 0)
        let b = reading(1_420_000, 160, wall: 1_150_000, at: 60)
        #expect(try #require(TelemetryMath.meanWatts(from: a, to: b)) == 7.0)
        #expect(abs(try #require(TelemetryMath.wallWatts(from: a, to: b)) - 9.0) < 1e-9)
        // 计数不前进或能量倒退时没有数值
        #expect(TelemetryMath.meanWatts(from: b, to: b) == nil)
        #expect(TelemetryMath.meanWatts(from: b, to: reading(1_000, 200, at: 120)) == nil)
    }

    @Test func droppedSegmentIsFlagged() {
        // 边界稿 §3.1：满载时一个 60 s 发布周期的计数只加 1
        let dropped = TelemetrySegment(
            end: Date(), seconds: 60, countDelta: 1, telemetryWatts: 19.4, integratedWatts: 78.1)
        #expect(dropped.isDropped)
        #expect(dropped.deviation == nil)
        let normal = TelemetrySegment(end: Date(), seconds: 60, countDelta: 60, telemetryWatts: 7.0, integratedWatts: 7.07)
        #expect(!normal.isDropped)
        #expect(abs((normal.deviation ?? 1) - 0.01) < 1e-9)
        // 刚开始的短段不判漏记
        #expect(!TelemetrySegment(end: Date(), seconds: 20, countDelta: 3, telemetryWatts: 7, integratedWatts: nil).isDropped)
    }
}

@Suite struct FanDiscoveryTests {
    @Test func modeKeyCaseDiffersByChip() {
        // M5 是 F0md，M4 是 F0Md（D44）
        let m5: Set = ["F0Ac", "F0Tg", "F0Mn", "F0Mx", "F0md"]
        let m4: Set = ["F0Ac", "F0Tg", "F0Mn", "F0Mx", "F0Md"]
        #expect(FanDiscovery.discover(count: 1) { m5.contains($0) }.first?.mode == "F0md")
        #expect(FanDiscovery.discover(count: 1) { m4.contains($0) }.first?.mode == "F0Md")
        #expect(FanDiscovery.discover(count: 1) { $0 == "F0Ac" }.first?.mode == nil)
    }

    @Test func noFans() {
        #expect(FanDiscovery.discover(count: 0) { _ in true }.isEmpty)
        // FNum 说有风扇但读不到实际转速键的风扇不出现
        #expect(FanDiscovery.discover(count: 2) { $0.hasPrefix("F1") }.map(\.index) == [1])
    }
}

@Suite struct HotspotLearnerTests {
    @Test func findsTheAggregateKey() {
        var learner = HotspotLearner()
        for i in 0..<HotspotLearner.minimumSamples {
            let base = 45.0 + Double(i % 7)
            // TCMz 恒等于最大值；Tp01、Tg05 轮流最大但 TCMz 总与最大值相同
            let a = base + (i.isMultiple(of: 2) ? 3 : 1)
            let b = base + (i.isMultiple(of: 2) ? 1 : 3)
            learner.observe(["Tp01": a, "Tg05": b, "TCMz": max(a, b), "Te04": base])
        }
        #expect(learner.result == "TCMz")
    }

    @Test func ignoresKeysThatNeverChange() {
        var learner = HotspotLearner()
        for i in 0..<HotspotLearner.maximumSamples {
            // 恒定的 99.0 永远最大，但从不变化，可能是停在旧值的读数，不采用
            learner.observe(["Tstuck": 99.0, "Tp01": 50 + Double(i % 5)])
        }
        #expect(learner.result == nil)
        #expect(learner.gaveUp)
    }
}

@Suite struct PMGRNamingTests {
    @Test func normalizesBothChipStyles() {
        let m5 = PMGRNaming.components(from: ["CPU Energy", "GPU0", "DRAM0", "FAB0", "PACC_0", "MCPU0", "AMCC0"])
        #expect(m5["gpu"] == "GPU0")
        #expect(m5["dram"] == "DRAM0")
        #expect(m5["fabric"] == "FAB0")
        #expect(m5["cpu"] == "CPU Energy")
        #expect(m5.values.contains("MCPU0") == false)
        let m4 = PMGRNaming.components(from: ["CPU Energy", "GPU", "DRAM", "ANE", "EACC_CPU"])
        #expect(m4 == ["cpu": "CPU Energy", "gpu": "GPU", "dram": "DRAM", "ane": "ANE"])
    }
}

@Suite struct PlaceholderTests {
    @Test func comparesAtFloatPrecision() {
        // SMC 的 flt 解码后 2.2 变成 2.2000000476837158，按 Float 比较才相等
        let decoded = Double(Float(2.2))
        #expect(decoded != 2.2)
        #expect(isPlaceholder(decoded, in: [2.2]))
        #expect(isPlaceholder(40.0, in: [-4, 0, 40]))
        #expect(!isPlaceholder(40.1, in: [-4, 0, 40]))
    }
}

@Suite struct PowerLedgerTests {
    @Test func twoConsecutiveFailuresDisable() {
        let ledger = PowerLedger()
        let range = PowerLedger.ranges[.gpu]!
        ledger.record(.gpu, ratio: 1.38, range: range, at: Date())
        #expect(!ledger.isDisabled(.gpu))
        ledger.record(.gpu, ratio: nil, range: range, at: Date())  // 不下结论：不清零也不累加
        #expect(!ledger.isDisabled(.gpu))
        ledger.record(.gpu, ratio: 1.40, range: range, at: Date())
        #expect(ledger.isDisabled(.gpu))
        ledger.record(.gpu, ratio: 0.96, range: range, at: Date())
        #expect(!ledger.isDisabled(.gpu))
    }

    @Test func dramIntegralBetweenCheckpoints() throws {
        let ledger = PowerLedger()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 1...10 { ledger.recordDRAM(watts: 0.5, seconds: 10, at: t0.addingTimeInterval(Double(i) * 10)) }
        let integral = try #require(ledger.dramIntegral(from: t0.addingTimeInterval(20), to: t0.addingTimeInterval(80)))
        #expect(abs(integral.joules - 30) < 1e-9)
        #expect(integral.covered == 60)
        #expect(integral.meanInterval == 10)
        #expect(ledger.dramIntegral(from: t0.addingTimeInterval(-500), to: t0) == nil)
    }
}

@Suite struct SystemProfileTests {
    @Test func bundledProfilesCarryTheSystemSection() throws {
        let profiles = ChipProfileStore.bundledProfiles()
        let m5 = try #require(profiles.first { $0.socID == "AppleT6050PMGR" }?.system)
        let m4 = try #require(profiles.first { $0.socID == "AppleT6041PMGR" }?.system)
        #expect(m5.hotspotKey == "TCMb")
        #expect(m4.hotspotKey == "TCMz")
        #expect(m5.pmgrComponents["gpu"] == "GPU0")
        #expect(m4.pmgrComponents["gpu"] == "GPU")
        #expect(m4.pmgrComponents["fabric"] == nil)
        #expect(m4.placeholders.contains(8.2))
    }

    @Test func profilesWithoutTheSectionStillDecode() throws {
        let profile = try #require(ChipProfileStore.bundledProfiles().first)
        var stripped = profile
        stripped.system = nil
        let data = try ChipProfileStore.encode(stripped)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"system\""))
        let decoded = try JSONDecoder().decode(ChipProfile.self, from: data)
        #expect(decoded.system == nil)
        #expect(decoded.temperature == profile.temperature)
    }
}
