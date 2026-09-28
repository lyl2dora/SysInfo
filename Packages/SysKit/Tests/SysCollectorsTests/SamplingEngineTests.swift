// SamplingEngine 的集成测试（M0 设计 §5.2，验收第 5 条）：用假采集器和真实定时器。
//
// 需要真实等待的测试各约 3–7 s；Swift Testing 默认并行执行，总时长取最长的那个。

import Foundation
import Synchronization
import SysModel
import Testing
@testable import SysCollectors

/// 记录调用次数的假采集器。
final class FakeCollector: Collector {
    struct Counts: Sendable {
        var samples = 0
        var selfTests = 0
        var resets = 0
    }

    let id: CollectorID
    private let status: CollectorStatus
    private let selfTestPasses: Bool
    private let counts = Mutex(Counts())

    init(_ id: CollectorID, status: CollectorStatus = .ok, selfTestPasses: Bool = true) {
        self.id = id
        self.status = status
        self.selfTestPasses = selfTestPasses
    }

    var snapshot: Counts { counts.withLock { $0 } }

    func selfTest() -> SelfTestResult {
        counts.withLock { $0.selfTests += 1 }
        return SelfTestResult(
            checks: [SelfTestCheck(name: "\(id).fake", passed: selfTestPasses, detail: "")], dataPath: "fake")
    }

    func sample(at time: SampleTime) -> CollectorOutput {
        let n = counts.withLock {
            $0.samples += 1
            return $0.samples
        }
        let metric = MetricID("\(id.rawValue).value")
        let samples: [Sample] =
            status == .unavailable
            ? [.unavailable(metric, reason: .readFailed(), at: time)]
            : [Sample(id: metric, value: Double(n), time: time)]
        return CollectorOutput(samples: samples, status: status, dataPath: "fake")
    }

    func resetBaseline() {
        counts.withLock { $0.resets += 1 }
    }
}

@Suite struct SamplingEngineTests {
    @Test func timerStopsAndTickCountFreezesWithoutDemand() async throws {
        let fake = FakeCollector("fake.a")
        let engine = SamplingEngine(collectors: [fake])
        #expect(await engine.status.isTimerArmed == false)

        let token = await engine.addDemand(Demand(collectors: ["fake.a"], interval: 1, source: .diagnostics))
        #expect(await engine.status.isTimerArmed)
        try await Task.sleep(for: .seconds(3))

        await engine.remove(token)
        let afterRemoval = await engine.status
        #expect(afterRemoval.tickCount >= 2, "3 s 内应当至少 tick 两次")
        #expect(!afterRemoval.isTimerArmed)
        #expect(afterRemoval.demands.isEmpty)

        try await Task.sleep(for: .seconds(3))
        let afterIdle = await engine.status
        #expect(afterIdle.tickCount == afterRemoval.tickCount, "注销需求后不应再 tick")
        #expect(fake.snapshot.samples == Int(afterRemoval.tickCount))
    }

    @Test func activationRunsSelfTestOnceAndResetsBaseline() async {
        let fake = FakeCollector("fake.a")
        let engine = SamplingEngine(collectors: [fake])
        let first = await engine.addDemand(Demand(collectors: ["fake.a"], interval: 1, source: .panel))
        #expect(fake.snapshot.selfTests == 1)
        #expect(fake.snapshot.resets == 1)

        // 已经有需求时再加一个，不是新激活：不重复自检、不丢基线
        let second = await engine.addDemand(Demand(collectors: ["fake.a"], interval: 5, source: .menubarCPU))
        #expect(fake.snapshot.selfTests == 1)
        #expect(fake.snapshot.resets == 1)
        #expect(await engine.status.effectiveIntervals == ["fake.a": 1])

        await engine.remove(first)
        #expect(await engine.status.effectiveIntervals == ["fake.a": 5])
        await engine.remove(second)

        // 重新获得需求：丢弃旧基线，但自检结果仍在，不重复自检
        let third = await engine.addDemand(Demand(collectors: ["fake.a"], interval: 1, source: .panel))
        #expect(fake.snapshot.resets == 2)
        #expect(fake.snapshot.selfTests == 1)
        await engine.remove(third)
    }

    @Test func releasingTheTokenCancelsTheDemand() async {
        let engine = SamplingEngine(collectors: [FakeCollector("fake.a")])
        do {
            _ = await engine.addDemand(Demand(collectors: ["fake.a"], interval: 1, source: .panel))
            // token 没有被持有，离开作用域即释放
        }
        // 注销经串行队列异步进入引擎；随后的 actor 调用排在它之后
        let status = await engine.status
        #expect(status.demands.isEmpty)
        #expect(!status.isTimerArmed)
    }

    @Test func pauseStopsTheTimerAndResumeRearmsIt() async {
        let fake = FakeCollector("fake.a")
        let engine = SamplingEngine(collectors: [fake])
        let token = await engine.addDemand(Demand(collectors: ["fake.a"], interval: 1, source: .menubarCPU))
        #expect(await engine.status.isTimerArmed)

        await engine.setThrottle(factor: .paused, reasons: [.screenLocked])
        let paused = await engine.status
        #expect(!paused.isTimerArmed)
        #expect(paused.demands.map(\.isActive) == [false])
        #expect(paused.throttleReasons == [.screenLocked])

        await engine.setThrottle(factor: .slowed(2), reasons: [.lowPowerMode])
        let slowed = await engine.status
        #expect(slowed.isTimerArmed)
        #expect(slowed.effectiveIntervals == ["fake.a": 2])
        #expect(fake.snapshot.resets == 2, "暂停后恢复算重新激活，要丢弃旧基线")

        await engine.setThrottle(factor: .normal, reasons: [])
        #expect(await engine.status.effectiveIntervals == ["fake.a": 1])
        await engine.remove(token)
    }

    @Test func tickResultBundlesAllDueCollectorsOnce() async throws {
        let a = FakeCollector("fake.a")
        let b = FakeCollector("fake.b")
        let engine = SamplingEngine(collectors: [a, b])
        let events = await engine.events()

        let token = await engine.addDemand(
            Demand(collectors: ["fake.a", "fake.b"], interval: 1, source: .panel))

        var ticks: [TickResult] = []
        for await event in events {
            if case .tick(let result) = event {
                ticks.append(result)
                if ticks.count == 2 { break }
            }
        }
        await engine.remove(token)

        for result in ticks {
            #expect(result.collectors == ["fake.a", "fake.b"])
            #expect(Set(result.samples.map(\.id)) == ["fake.a.value", "fake.b.value"])
            #expect(result.samples.allSatisfy { $0.time == result.time })
            #expect(result.status.nextTick != nil, "tick 结果里的状态应当反映已排定的下一次唤醒")
        }
        #expect(ticks[1].tick > ticks[0].tick)
        #expect(ticks[1].status.tickCount == ticks[0].status.tickCount + 1)
        let health = ticks[1].status.health.first { $0.id == "fake.a" }
        #expect(health?.sampleCount == 2)
        #expect(health?.lastCost != nil)
        #expect(health?.averageCost != nil)
    }

    @Test func consecutiveUnavailableTriggersRecheck() async throws {
        let broken = FakeCollector("fake.broken", status: .unavailable, selfTestPasses: false)
        let engine = SamplingEngine(
            collectors: [broken], configuration: .init(recheckAfterConsecutiveUnavailable: 2))
        let token = await engine.addDemand(Demand(collectors: ["fake.broken"], interval: 1, source: .panel))
        #expect(broken.snapshot.selfTests == 1)

        try await Task.sleep(for: .seconds(3.2))
        await engine.remove(token)
        // 至少 2 次采样都不可用 → 至少复检一次
        #expect(broken.snapshot.samples >= 2)
        #expect(broken.snapshot.selfTests >= 2)
        let health = await engine.status.health.first
        #expect(health?.status == .unavailable)
        #expect(health?.selfTest?.passed == false)
    }

    @Test func eventsStartWithCurrentStatus() async {
        let engine = SamplingEngine(collectors: [FakeCollector("fake.a")])
        var iterator = await engine.events().makeAsyncIterator()
        guard case .status(let status) = await iterator.next() else {
            Issue.record("第一个事件应当是状态")
            return
        }
        #expect(status.tickCount == 0)
        #expect(status.health.map(\.id) == ["fake.a"])
    }
}
