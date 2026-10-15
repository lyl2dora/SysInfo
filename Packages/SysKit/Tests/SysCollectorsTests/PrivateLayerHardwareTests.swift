// 私有层的硬件测试（CPU 模块设计 §9）：读真实机器，默认跳过，`make test-hw` / `make remote-test` 运行。
// 断言只用运行时发现的值，不写死任何芯片的通道名、键名或核数（D20）。

import Darwin
import Dispatch
import Synchronization
import Testing
@testable import SysCollectors

@Suite(.tags(.hardware), .hardwareOnly)
struct PrivateLayerHardwareTests {
    // MARK: IOReport

    @Test func ioReportEnumeratesEachGroupOnce() throws {
        let hub = IOReportHub()
        #expect(hub.isAvailable)
        let first = try #require(hub.channels(inGroup: "CPU Stats"))
        #expect(!first.isEmpty)
        let second = try #require(hub.channels(inGroup: "CPU Stats"))
        #expect(first == second)
        #expect(hub.enumerationCount == 1, "同一个组只应枚举一次")
    }

    /// 状态驻留是积分量：一个通道各状态驻留增量之和 / 墙钟 ≈ timebase 频率（边界稿 §2.2：0.97–1.02）。
    @Test func performanceStateResidenciesAddUpToElapsedTime() throws {
        let hub = IOReportHub()
        let subscription = try #require(
            hub.makeSubscription(selecting: [
                (group: "CPU Stats", include: { $0.key.subgroup == "CPU Complex Performance States" })
            ]))
        #expect(subscription.channelCount > 0)
        let baseline = try #require(subscription.sampleDelta())
        #expect(baseline.isEmpty, "第一次只建立基线")
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        usleep(300_000)
        let deltas = try #require(subscription.sampleDelta())
        let elapsedNanos = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
        let timebase = try #require(MachTimebase.current)
        let ticksPerNano = Double(timebase.denom) / Double(timebase.numer)
        // 只看带 IDLE 状态的标准性能状态通道。`*_IDLE` 通道（状态里是 NON_IDLE）不是完整的时间积分：
        // 2026-10-15 在 M4 Pro 上实测 PCPM_IDLE 的驻留/墙钟只有 0.48；频率发现按结构规则本来就排除它（设计 §5.4）。
        let stateChannels = deltas.filter { $0.stateNames.contains("IDLE") }
        #expect(!stateChannels.isEmpty)
        for channel in stateChannels {
            let ratio = Double(channel.stateResidencies.reduce(0, +)) / (elapsedNanos * ticksPerNano)
            #expect(ratio > 0.9 && ratio < 1.1, "\(channel.key)：驻留/墙钟 = \(ratio)")
        }
    }

    /// 回归（2026-10-15）：IOReport 的通道访问器会往通道字典里写缓存，并发读同一份缓存字典曾导致崩溃。
    /// 多个线程同时读通道信息、建订阅并采样，不应崩溃，结果也应一致。
    @Test func concurrentChannelAccessAndSubscriptions() {
        let hub = IOReportHub()
        let counts = Mutex([Int]())
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            for _ in 0..<5 {
                let infos = hub.channels(inGroup: "CPU Stats") ?? []
                let subscription = hub.makeSubscription(selecting: [
                    (group: "CPU Stats", include: { $0.key.subgroup == "CPU Core Performance States" })
                ])
                _ = subscription?.sampleDelta()
                _ = subscription?.sampleDelta()
                counts.withLock { $0.append(infos.count) }
            }
            _ = i
        }
        let all = counts.withLock { $0 }
        #expect(all.count == 80)
        #expect(Set(all).count == 1 && all[0] > 0)
        #expect(hub.enumerationCount == 1)
    }

    // MARK: SMC

    @Test func smcEnumeratesKeysAndReadsATemperature() throws {
        let smc = SMCReader()
        try smc.open()
        let count = try smc.keyCount()
        #expect(count > 100)
        let keys = try smc.allKeys()
        #expect(Double(keys.count) >= 0.9 * Double(count), "枚举到 \(keys.count) / \(count)")
        // 至少有一个 T 开头、flt 类型、读数在合理范围的键（不写死键名，D20）。
        var plausible = 0
        for key in keys where key.description.hasPrefix("T") {
            guard let info = try? smc.keyInfo(for: key), info.dataType == "flt " else { continue }
            if let value = try? smc.readValue(key), (5...130).contains(value) { plausible += 1 }
            if plausible >= 3 { break }
        }
        #expect(plausible >= 3)
    }

    @Test func smcReportsMissingKeyAsSMCResult() throws {
        let smc = SMCReader()
        try smc.open()
        #expect(throws: SMCError.self) { try smc.keyInfo(for: "zz?!") }
    }

    // MARK: coalition

    @Test func coalitionSelfTestStructuralChecks() throws {
        #expect(CoalitionReader.isAvailable)
        let entries = try #require(CoalitionReader.list())
        #expect(entries.count > 10)
        let mine = try #require(CoalitionReader.coalition(ofPID: getpid()))
        #expect(entries.contains { $0.id == mine })
        let probe = try #require(CoalitionReader.probeUsage(of: mine))
        #expect(probe.bytesWritten >= CoalitionUsage.minimumBytes)
        #expect(probe.usage.eqosLength == CoalitionUsage.expectedEQoSLength)
        let members = try #require(CoalitionReader.members(of: mine, tasksHint: 1))
        #expect(members.contains(getpid()))
    }

    @Test func coalitionCPUTimeAdvancesWithOwnWork() throws {
        let mine = try #require(CoalitionReader.coalition(ofPID: getpid()))
        let before = try #require(CoalitionReader.usage(of: mine)).cpuTicks
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 60_000_000
        var x = 0.0
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { x += 1 }
        #expect(x > 0)
        let after = try #require(CoalitionReader.usage(of: mine)).cpuTicks
        #expect(after > before)
    }

    // MARK: proc_pidinfo 私有 flavor

    @Test func threadCountsCoverEveryPerfLevel() throws {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        let levels = try #require(ProcessPrivateInfo.threadCounts(threadID: tid))
        let nperflevels = try #require(SystemInfo.sysctlInt32("hw.nperflevels"))
        #expect(levels.count == Int(nperflevels))
        #expect(levels.contains { $0.cycles > 0 })
    }

    @Test func uniqueIDIsStableForOwnProcess() throws {
        let a = try #require(ProcessPrivateInfo.uniqueID(of: getpid()))
        let b = try #require(ProcessPrivateInfo.uniqueID(of: getpid()))
        #expect(a == b && a != 0)
    }
}
