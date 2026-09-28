// 硬件测试（K25，M0 设计 §8）：读真实机器，默认跳过，`make test-hw` 运行。
// 断言只用运行时发现的值（hw.logicalcpu 等），不写死任何机型的核数（D20）。

import Darwin
import SysModel
import Testing
@testable import SysCollectors

@Suite(.tags(.hardware), .hardwareOnly)
struct HardwareTests {
    @Test func hostProcessorInfoMatchesLogicalCPUCount() throws {
        let logical = try #require(SystemInfo.logicalCPUCount)
        let ticks = try CPULoadCollector.readTicks().get()
        #expect(ticks.count == logical)
    }

    @Test func tickCountersAreMonotonicAcrossReads() throws {
        let first = try CPULoadCollector.readTicks().get()
        usleep(50_000)
        let second = try CPULoadCollector.readTicks().get()
        #expect(first.count == second.count)
        for (index, pair) in zip(first, second).enumerated() {
            #expect(pair.1.isMonotonic(since: pair.0), "cpu\(index) 的计数器回退")
        }
    }

    @Test func cpuLoadCollectorPassesSelfTestAndProducesRatios() throws {
        let collector = CPULoadCollector()
        let selfTest = collector.selfTest()
        #expect(selfTest.passed, "\(selfTest.checks.filter { !$0.passed })")

        #expect(collector.sample(at: .now()).samples.isEmpty, "第一次只建立基线")
        usleep(300_000)
        let output = collector.sample(at: .now())
        #expect(output.status == .ok)
        let total = try #require(output.samples.first { $0.id == .cpuUsageTotal })
        let value = try #require(total.value)
        #expect((0...1).contains(value))
        #expect(output.samples.count == 1 + (SystemInfo.logicalCPUCount ?? -1))
    }

    @Test func procPidRusageIsReadable() throws {
        let usage = try SelfUsageCollector.readUsage().get()
        #expect(usage.footprint > 0)
        #expect(usage.cpuTicks > 0)
    }

    @Test func selfUsageCollectorPassesSelfTestAndMeasuresBusyLoop() throws {
        let collector = SelfUsageCollector()
        let selfTest = collector.selfTest()
        #expect(selfTest.passed, "\(selfTest.checks.filter { !$0.passed })")

        _ = collector.sample(at: .now())
        // 忙等约 200 ms：本进程 CPU（按单核）应当明显大于 0
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var x: UInt64 = 0
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start < 200_000_000 { x &+= 1 }
        #expect(x > 0)
        let output = collector.sample(at: .now())
        #expect(output.status == .ok)
        let cpu = try #require(output.samples.first { $0.id == .appSelfCPU }?.value)
        #expect(cpu > 0.3, "忙等期间本进程 CPU 只有 \(cpu)")
        let footprint = try #require(output.samples.first { $0.id == .appSelfFootprint }?.value)
        #expect(footprint > 0)
    }

    @Test func allStandardCollectorsPassSelfTest() {
        for collector in StandardCollectors.make() {
            let result = collector.selfTest()
            #expect(result.passed, "\(collector.id)：\(result.checks.filter { !$0.passed })")
        }
    }
}
