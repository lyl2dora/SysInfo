// GPU 与加速器（GPU 模块设计 §5、§6）：档位表选择、GPUPH 驻留换算、温度取值、媒体引擎底数、ANE 对账、档案 gpu 段；
// 硬件测试（默认跳过）核对各采集器在本机的自检与读数范围。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

/// 把（频率, 电压）对编码成 pmgr 表的原始字节（小端 UInt32 × 2）。
private func table(_ frequencies: [UInt32]) -> Data {
    var data = Data()
    for f in frequencies {
        withUnsafeBytes(of: f.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(800).littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private let mhz: UInt32 = 1_000_000

@Suite struct GPUFrequencyTableTests {
    // 2026-10-16 实测（GPU 边界稿 §1.1）：M5 的 GPU 表 13 个非零档，M4 15 个且中间不单调；CPU 表是 kHz。
    static let m5GPU = table([0] + [338, 486, 636, 796, 888, 988, 1084, 1182, 1278, 1374, 1470, 1578, 1620].map { $0 * mhz })
    static let m4GPU = table([0] + [338, 618, 796, 924, 952, 1056, 1062, 1182, 1182, 1312, 1242, 1380, 1326, 1470, 1578].map { $0 * mhz })
    static let cpuKHz = table([1_308_000, 2_292_000, 4_608_000])

    @Test func profileKeyIsUsed() throws {
        let t = try #require(
            GPUFrequencyDiscovery.table(
                rawTables: [9: Self.m5GPU, 14: Self.m5GPU, 5: Self.cpuKHz], cpuTableKeys: [5], pStateCount: 15, preferredKey: 9))
        #expect(t.key == 9 && t.fromProfile)
        #expect(t.frequencies.count == 13)
        #expect(t.frequency(ofPState: 1) == 338e6)
        #expect(t.frequency(ofPState: 13) == 1620e6)
        #expect(t.frequency(ofPState: 14) == nil)
    }

    @Test func orderIsKeptWhenNotMonotonic() throws {
        let t = try #require(
            GPUFrequencyDiscovery.table(rawTables: [9: Self.m4GPU], cpuTableKeys: [], pStateCount: 15, preferredKey: 9))
        #expect(t.frequency(ofPState: 11) == 1242e6)  // 不排序：P11 在 P10（1312）之后
        #expect(t.top == 1578e6)
    }

    @Test func inferenceSkipsCPUAndKHzTables() throws {
        // 没有档案：排除 CPU 表与 kHz 表，取档数最多（不超过 P 档数）的 Hz 表；同档数取键号最小的
        let t = try #require(
            GPUFrequencyDiscovery.table(
                rawTables: [9: Self.m5GPU, 14: Self.m5GPU, 5: Self.cpuKHz, 22: table([800 * mhz, 1600 * mhz, 2000 * mhz, 2400 * mhz, 3000 * mhz])],
                cpuTableKeys: [22], pStateCount: 15, preferredKey: nil))
        #expect(t.key == 9 && !t.fromProfile)
        // 档案指定的表档数超过 P 档数：不用
        #expect(
            GPUFrequencyDiscovery.table(rawTables: [9: Self.m4GPU], cpuTableKeys: [], pStateCount: 13, preferredKey: 9) == nil)
        #expect(GPUFrequencyDiscovery.hertzFrequencies(Self.cpuKHz) == nil)
    }
}

@Suite struct GPUResidencyTests {
    static let names = ["OFF"] + (1...15).map { "P\($0)" }

    private func residencies(_ pairs: [Int: Int64]) -> [Int64] {
        (0..<Self.names.count).map { pairs[$0] ?? 0 }
    }

    @Test func activeAndWeightedFrequency() throws {
        let t = GPUFrequencyTable(key: 9, frequencies: [338e6, 486e6, 636e6], fromProfile: true)
        // OFF 50%，P1 25%，P3 25%：活跃 50%，活跃期间平均 (338 + 636) / 2 MHz
        let s = GPUResidencyMath.summarize(names: Self.names, residencies: residencies([0: 2, 1: 1, 3: 1]), table: t)
        #expect(s.active == 0.5)
        #expect(abs((s.frequency ?? 0) - 487e6) < 1)
        #expect(s.averageState == 2)
        #expect(!s.exceedsTable)
        let sample = GPUPowerCollector.frequencySample(s, table: t, at: .now())
        #expect(sample.quality == .measured)
    }

    @Test func negativeResidencyIsCounterReset() {
        let t = GPUFrequencyTable(key: 9, frequencies: [338e6, 486e6, 636e6], fromProfile: true)
        let s = GPUResidencyMath.summarize(names: Self.names, residencies: residencies([0: -5, 1: 1, 3: 1]), table: t)
        #expect(s.counterReset)
        #expect(s.active == nil)
        #expect(s.frequency == nil)
    }

    @Test func offWholeIntervalIsDeviceIdle() {
        let t = GPUFrequencyTable(key: 9, frequencies: [338e6], fromProfile: false)
        let s = GPUResidencyMath.summarize(names: Self.names, residencies: residencies([0: 100]), table: t)
        #expect(s.active == 0)
        #expect(s.frequency == nil)
        let sample = GPUPowerCollector.frequencySample(s, table: t, at: .now())
        guard case .unavailable(let reason) = sample.quality else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.code == "deviceIdle")
    }

    @Test func stateBeyondTableMakesFrequencyUntrusted() {
        let t = GPUFrequencyTable(key: 9, frequencies: [338e6, 486e6], fromProfile: true)
        let s = GPUResidencyMath.summarize(names: Self.names, residencies: residencies([5: 10]), table: t)
        #expect(s.exceedsTable)
        #expect(s.frequency == nil)
        #expect(s.active == 1)
    }

    @Test func noResidencyHasNoActive() {
        let s = GPUResidencyMath.summarize(names: Self.names, residencies: residencies([:]), table: nil)
        #expect(s.active == nil)
        #expect(GPUResidencyMath.pStateIndex("OFF") == 0)
        #expect(GPUResidencyMath.pStateIndex("P13") == 13)
        #expect(GPUResidencyMath.pStateIndex("SW_P1") == nil)
    }
}

@Suite struct GPUTemperatureTests {
    @Test func placeholdersAreNotReadings() throws {
        // M4 实测：GPU 关断时 −4、0、2.2、2.4（D57 G4）
        let profile = try #require(ChipProfileStore.bundledProfiles().first { $0.socID == "AppleT6041PMGR" }?.gpu)
        let off = ["Tg1U": -4.0, "Tg1k": 2.4, "Tg0j": 0, "Tg1c": 2.2]
        #expect(GPUTemperatureMath.maximum(off, isValid: profile.isValid) == nil)
        let on = ["Tg1U": 61.2, "Tg1k": 63.9, "Tg0j": -4.0]
        #expect(GPUTemperatureMath.maximum(on, isValid: profile.isValid) == 63.9)
        #expect(!GPUTemperatureMath.fallbackValid(2.4))
        #expect(GPUTemperatureMath.fallbackValid(45))
    }

    @Test func bundledProfilesCarryTheGPUSection() throws {
        for profile in ChipProfileStore.bundledProfiles() {
            let gpu = try #require(profile.gpu, "\(profile.socID) has no gpu section")
            #expect(gpu.dvfsTableKey == 9)
            #expect(gpu.temperatureKeys.count == 5)
            #expect(gpu.temperatureKeys.allSatisfy { $0.hasPrefix("Tg") && $0.count == 4 })
        }
    }
}

@Suite struct InterruptBaselineTests {
    @Test func learnsTheIdleFloor() {
        var b = InterruptBaseline()
        // M5 的 avd 空闲约 90 次/s：学习期内返回 nil
        for _ in 0..<(InterruptBaseline.minimumSamples - 1) { #expect(b.observe(90) == nil) }
        #expect(b.observe(91) == 1)
        #expect(b.observe(2_250) == 2_160)  // 解码时减去底数
        #expect(b.observe(80) == 0)  // 更低的读数成为新底数
        #expect(b.baseline == 80)
    }
}

@Suite struct ANECrossCheckTests {
    @Test func aneBatchIsReconciled() {
        let ledger = PowerLedger()
        let pmgr = PMGRBatchCollector(ledger: ledger)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 每 10 s 一个窗口，一共覆盖 1800 s，每个窗口 1 J（槽位 39 合计）→ 180 J
        ledger.recordANE(joules: 0, seconds: 10, at: t0)
        for i in 1...180 { ledger.recordANE(joules: 1, seconds: 10, at: t0.addingTimeInterval(Double(i) * 10)) }
        let batch = PMGRBatch(start: t0, end: t0.addingTimeInterval(1800), joules: ["ane": 196], agxJoules: nil)
        pmgr.crossCheck(batch)
        let check = ledger.checks.first { $0.name == "ane" }
        #expect(check?.verdict == .passed)
        #expect(abs((check?.ratio ?? 0) - 180.0 / 196) < 1e-9)
        #expect(!ledger.isDisabled(.ane))
    }

    @Test func lowANEUsageIsInconclusiveAndRepeatedFailureDisables() {
        let ledger = PowerLedger()
        let pmgr = PMGRBatchCollector(ledger: ledger)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        ledger.recordANE(joules: 0, seconds: 10, at: t0)
        for i in 1...180 { ledger.recordANE(joules: 0.1, seconds: 10, at: t0.addingTimeInterval(Double(i) * 10)) }
        // 窗口均值 0.03 W < 0.05 W：不下结论
        pmgr.crossCheck(PMGRBatch(start: t0, end: t0.addingTimeInterval(1800), joules: ["ane": 54], agxJoules: nil))
        #expect(ledger.checks.first { $0.name == "ane" }?.verdict == .inconclusive)
        // 积分只有批次的一半：连续两次失败后停用估算
        for _ in 0..<2 {
            pmgr.crossCheck(PMGRBatch(start: t0, end: t0.addingTimeInterval(1800), joules: ["ane": 36 * 1800 / 100], agxJoules: nil))
        }
        #expect(ledger.isDisabled(.ane))
    }
}

@Suite(.tags(.hardware), .hardwareOnly) struct GPUHardwareTests {
    @Test func gpuActivityAndFrequency() throws {
        let gpu = GPUPowerCollector(ledger: PowerLedger())
        let result = gpu.selfTest()
        #expect(result.isUsable)
        #expect(gpu.hasResidency)
        let table = try #require(gpu.frequencyTable)
        #expect(table.fromProfile)
        #expect(table.top > 1e9 && table.top < 3e9)
        _ = gpu.sample(at: .now())
        Thread.sleep(forTimeInterval: 0.5)
        let samples = gpu.sample(at: .now()).samples
        let active = try #require(samples.first { $0.id == .gpuActive }?.value)
        #expect(active >= 0 && active <= 1)
        #expect(samples.contains { $0.id == .gpuFrequency })
    }

    @Test func temperatureAcceleratorsAndMedia() throws {
        let temperature = GPUTemperatureCollector()
        #expect(temperature.selfTest().isUsable)
        let t = try #require(temperature.sample(at: .now()).samples.first)
        if let value = t.value { #expect(value > 10 && value < 130) }  // M4 上 GPU 关断时没有读数
        let accelerators = GPUAcceleratorCollector()
        #expect(accelerators.selfTest().isUsable)
        let memory = try #require(accelerators.sample(at: .now()).samples.first { $0.id == .gpuMemoryAllocated }?.value)
        #expect(memory > 0)
        let media = MediaEngineCollector()
        #expect(media.selfTest().isUsable)
        _ = media.sample(at: .now())
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!media.sample(at: .now()).samples.isEmpty)
    }
}
