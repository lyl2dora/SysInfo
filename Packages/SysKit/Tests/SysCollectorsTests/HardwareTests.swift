// 硬件测试（K25，M0 设计 §8）：读真实机器，默认跳过，`make test-hw` 运行。
// 断言只用运行时发现的值（hw.logicalcpu_max 等），不写死任何机型的核数（D20）。

import Darwin
import SysModel
import Testing
@testable import SysCollectors

@Suite(.tags(.hardware), .hardwareOnly)
struct HardwareTests {
    /// host_processor_info 返回全部已注册的处理器，对照 hw.logicalcpu_max（不是「当前电源模式下可用」的 hw.logicalcpu）。
    @Test func hostProcessorInfoMatchesMaxLogicalCPUCount() throws {
        let logical = try #require(SystemInfo.maxLogicalCPUCount)
        let ticks = try CPULoadCollector.readTicks().get()
        #expect(ticks.count == logical)
    }

    /// 回归：每次读 tick 都调用 mach_host_self() 会让 host 端口的 send right 引用计数一直涨（到 65535 饱和）。
    @Test func readingTicksDoesNotLeakHostPortReferences() throws {
        func sendRefs() -> mach_port_urefs_t {
            var refs: mach_port_urefs_t = 0
            let kr = mach_port_get_refs(mach_task_self_, CPULoadCollector.host, MACH_PORT_RIGHT_SEND, &refs)
            #expect(kr == KERN_SUCCESS)
            return refs
        }
        let before = sendRefs()
        for _ in 0..<2000 {
            _ = try CPULoadCollector.readTicks().get()
        }
        let after = sendRefs()
        // 并行的其他测试或系统框架偶尔也会取 host 端口，所以只要求远小于读取次数。
        #expect(after >= before)
        #expect(after - before < 100, "2000 次读取后 urefs \(before) → \(after)")
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
        // 每核样本数等于核数；另有用户/系统和按拓扑汇总的每簇、每档样本（CPU 模块设计 §5.3）。
        #expect(output.samples.filter { $0.id.cpuCoreIndex != nil }.count == (SystemInfo.maxLogicalCPUCount ?? -1))
        #expect(output.samples.contains { $0.id == .cpuUsageUser })
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
