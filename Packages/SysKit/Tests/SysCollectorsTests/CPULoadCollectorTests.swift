// CPULoadCollector 的自检与采样逻辑（K19，D24 修订：按通道逐项判定）：用假读数，不读真实硬件。

import Foundation
import Synchronization
import SysModel
import Testing
@testable import SysCollectors

/// 按顺序返回预设读数的假读取函数；读完之后一直返回最后一个。
private final class ScriptedTicks: Sendable {
    typealias Reading = Result<[CoreTicks], CPULoadCollector.ReadError>
    private let readings: Mutex<[Reading]>

    init(_ readings: [Reading]) {
        precondition(!readings.isEmpty)
        self.readings = Mutex(readings)
    }

    func next() -> Reading {
        readings.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

/// 每个核给 (busy, idle) tick；busy 全算在 user 上。
private func cores(_ values: [(UInt32, UInt32)]) -> [CoreTicks] {
    values.map { CoreTicks(user: $0.0, system: 0, idle: $0.1, nice: 0) }
}

private func collector(_ script: ScriptedTicks, maxLogical: Int? = 2) -> CPULoadCollector {
    CPULoadCollector(readTicks: { script.next() }, maxLogicalCPUCount: { maxLogical })
}

private let time = SampleTime(monotonicNanos: 1, wallClock: .init(timeIntervalSince1970: 0))

@Suite struct CPULoadCollectorTests {
    @Test func healthyReadingsPassAndMeasure() throws {
        let script = ScriptedTicks([
            .success(cores([(10, 90), (20, 80)])),  // 自检第 1 次
            .success(cores([(11, 99), (21, 89)])),  // 自检第 2 次（单调）
            .success(cores([(11, 99), (21, 89)])),  // 基线
            .success(cores([(21, 189), (71, 139)])),  // +10/+90、+50/+50
        ])
        let cpu = collector(script)
        let selfTest = cpu.selfTest()
        #expect(selfTest.passed)
        #expect(selfTest.isUsable)

        #expect(cpu.sample(at: time).samples.isEmpty)
        let output = cpu.sample(at: time)
        #expect(output.status == .ok)
        let total = try #require(output.samples.first { $0.id == .cpuUsageTotal })
        #expect(total.quality == .measured)
        #expect(total.value == 0.3)
    }

    /// 某个核的计数器为 0（例如没上线的核）：不停用整个数据源，只把该核标为不可用、总占用标为估算、状态降级。
    @Test func zeroTickCoreOnlyDegrades() throws {
        let script = ScriptedTicks([
            .success(cores([(10, 90), (0, 0)])),
            .success(cores([(11, 99), (0, 0)])),
            .success(cores([(11, 99), (0, 0)])),
            .success(cores([(21, 189), (0, 0)])),
        ])
        let cpu = collector(script)
        let selfTest = cpu.selfTest()
        #expect(!selfTest.passed)
        #expect(selfTest.isUsable)
        #expect(selfTest.warnings.map(\.name) == ["cpu.load.nonzero"])

        let baseline = cpu.sample(at: time)
        #expect(baseline.samples.isEmpty)
        #expect(baseline.status == .degraded)

        let output = cpu.sample(at: time)
        #expect(output.status == .degraded)
        let total = try #require(output.samples.first { $0.id == .cpuUsageTotal })
        #expect(total.quality == .estimated)
        #expect(total.value == 0.1)
        let core0 = try #require(output.samples.first { $0.id == .cpuUsageCore(0) })
        #expect(core0.value == 0.1)
        let core1 = try #require(output.samples.first { $0.id == .cpuUsageCore(1) })
        #expect(core1.value == nil)
        #expect(core1.quality.isUnavailable)
    }

    /// 核数与 hw.logicalcpu_max 对不上：读数本身仍然正确，照常出数，只降级。
    @Test func coreCountMismatchOnlyDegrades() throws {
        let script = ScriptedTicks([
            .success(cores([(10, 90), (20, 80)])),
            .success(cores([(11, 99), (21, 89)])),
            .success(cores([(11, 99), (21, 89)])),
            .success(cores([(21, 189), (71, 139)])),
        ])
        let cpu = collector(script, maxLogical: 4)
        let selfTest = cpu.selfTest()
        #expect(selfTest.isUsable)
        #expect(selfTest.warnings.map(\.name) == ["cpu.load.coreCount"])
        #expect(selfTest.checks.first { $0.name == "cpu.load.coreCount" }?.detail.contains("hw.logicalcpu_max=4") == true)

        _ = cpu.sample(at: time)
        let output = cpu.sample(at: time)
        #expect(output.status == .degraded)
        let total = try #require(output.samples.first { $0.id == .cpuUsageTotal })
        #expect(total.quality == .measured)
        #expect(total.value == 0.3)
    }

    /// 读取失败是必需项：整个数据源不可用，不输出数值（D05）。
    @Test func readFailureMakesTheSourceUnavailable() throws {
        let script = ScriptedTicks([.failure(.init(description: "host_processor_info kr=5"))])
        let cpu = collector(script)
        let selfTest = cpu.selfTest()
        #expect(!selfTest.isUsable)

        let output = cpu.sample(at: time)
        #expect(output.status == .unavailable)
        let total = try #require(output.samples.first { $0.id == .cpuUsageTotal })
        #expect(total.value == nil)
    }

    /// 必需项不通过、之后又能读了：复检通过后丢弃旧基线，恢复出数。
    @Test func recoversAfterARequiredCheckPassesAgain() throws {
        let script = ScriptedTicks([
            .failure(.init(description: "kr=5")),  // 自检：不可用
            .success(cores([(10, 90), (20, 80)])),  // 采样：自检不可用，标为不可用
            .success(cores([(11, 99), (21, 89)])),  // 复检第 1 次
            .success(cores([(11, 99), (21, 89)])),  // 复检第 2 次
            .success(cores([(11, 99), (21, 89)])),  // 基线
            .success(cores([(21, 189), (71, 139)])),
        ])
        let cpu = collector(script)
        #expect(!cpu.selfTest().isUsable)
        #expect(cpu.sample(at: time).status == .unavailable)
        #expect(cpu.selfTest().passed)
        #expect(cpu.sample(at: time).samples.isEmpty)
        let output = cpu.sample(at: time)
        #expect(output.status == .ok)
        #expect(output.samples.first { $0.id == .cpuUsageTotal }?.value == 0.3)
    }
}

@Suite struct SelfTestResultTests {
    @Test func advisoryFailuresKeepTheSourceUsable() {
        let result = SelfTestResult(
            checks: [
                SelfTestCheck(name: "read", passed: true, detail: ""),
                SelfTestCheck(name: "hint", passed: false, detail: "", severity: .advisory),
            ], dataPath: "x")
        #expect(!result.passed)
        #expect(result.isUsable)
        #expect(result.warnings.map(\.name) == ["hint"])
    }

    @Test func requiredFailureMakesTheSourceUnusable() {
        let result = SelfTestResult(
            checks: [SelfTestCheck(name: "read", passed: false, detail: "")], dataPath: "x")
        #expect(!result.passed)
        #expect(!result.isUsable)
        #expect(result.warnings.isEmpty)
        #expect(!SelfTestResult(checks: [], dataPath: "x").isUsable)
    }

    @Test func checksWithoutSeverityDecodeAsRequired() throws {
        let json = #"{"name":"read","passed":false,"detail":"kr=5"}"#
        let check = try JSONDecoder().decode(SelfTestCheck.self, from: Data(json.utf8))
        #expect(check.severity == .required)
    }
}
