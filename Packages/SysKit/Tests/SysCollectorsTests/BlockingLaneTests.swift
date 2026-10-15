// 阻塞通道（CPU 模块设计 §5.1）：慢采集器不拖慢主 tick，结果单独交付，忙时跳过并计数。

import Foundation
import Synchronization
import SysModel
import Testing
@testable import SysCollectors

/// 每次采样阻塞 `delay` 秒的假采集器。
private final class SlowCollector: Collector {
    let id: CollectorID = "fake.slow"
    let lane: CollectorLane = .blocking
    private let delay: Double
    let calls = Mutex(0)

    init(delay: Double) { self.delay = delay }

    func selfTest() -> SelfTestResult {
        SelfTestResult(checks: [SelfTestCheck(name: "fake.slow", passed: true, detail: "")], dataPath: "fake")
    }

    func sample(at time: SampleTime) -> CollectorOutput {
        calls.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: delay)
        return CollectorOutput(samples: [Sample(id: "fake.slow.value", value: 1, time: time)], status: .ok, dataPath: "fake")
    }

    func resetBaseline() {}
}

@Suite struct BlockingLaneTests {
    @Test func slowCollectorRunsOffTheMainTick() async throws {
        let fast = FakeCollector("fake.fast")
        let slow = SlowCollector(delay: 1.6)
        let engine = SamplingEngine(collectors: [fast, slow])
        let events = await engine.events()
        let token = await engine.addDemand(Demand(collectors: ["fake.fast", "fake.slow"], interval: 1, source: .diagnostics))

        var inlineTicks: [Int64] = []
        var blockingTicks: [Int64] = []
        let deadline = Date().addingTimeInterval(5.5)
        for await event in events {
            guard case .tick(let result) = event else { continue }
            switch result.lane {
            case .inline:
                #expect(result.collectors == ["fake.fast"], "主 tick 里不应包含阻塞采集器")
                #expect(result.cost.wallNanos < 500_000_000, "慢采集器不应拖慢主 tick")
                inlineTicks.append(result.tick)
            case .blocking:
                #expect(result.collectors == ["fake.slow"])
                #expect(result.samples.map(\.id) == ["fake.slow.value"])
                blockingTicks.append(result.tick)
            }
            if Date() > deadline { break }
        }
        await engine.remove(token)
        let health = await engine.status.health.first { $0.id == "fake.slow" }

        #expect(inlineTicks.count >= 4, "5 s 内主 tick 应照常每秒一次：\(inlineTicks)")
        #expect(blockingTicks.count >= 2 && blockingTicks.count < inlineTicks.count)
        #expect(Set(blockingTicks).isSubset(of: Set(inlineTicks)), "阻塞结果沿用同一个 tick 序号")
        #expect((health?.skippedBusyCount ?? 0) >= 1, "上一次没结束时应跳过并计数")
        #expect(health?.sampleCount == UInt64(blockingTicks.count))
    }
}
