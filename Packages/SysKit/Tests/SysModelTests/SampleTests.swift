// 样本、数据质量、自检结果与小组件快照（K17、K31，M0 设计 §4）。

import Foundation
import Testing
import SysModel

@Suite struct SampleTests {
    let time = SampleTime(monotonicNanos: 123_456_789, wallClock: Date(timeIntervalSince1970: 1_790_000_000))

    @Test func measuredSampleCarriesValue() {
        let sample = Sample(id: .cpuUsageTotal, value: 0.25, time: time)
        #expect(sample.value == 0.25)
        #expect(sample.quality == .measured)
        #expect(!sample.quality.isUnavailable)
    }

    @Test func unavailableSampleHasNoValue() {
        let sample = Sample.unavailable(.cpuUsageTotal, reason: .readFailed("kr=5"), at: time)
        #expect(sample.value == nil)
        #expect(sample.quality.isUnavailable)
        #expect(sample.quality == .unavailable(UnavailableReason(code: "readFailed", detail: "kr=5")))
    }

    @Test(arguments: [
        DataQuality.measured, .batched30min, .estimated, .relative, .inferred,
        .unavailable(.counterReset()), .unavailable(.selfTestFailed("x")),
    ])
    func dataQualityRoundTrips(quality: DataQuality) throws {
        let data = try JSONEncoder().encode(quality)
        #expect(try JSONDecoder().decode(DataQuality.self, from: data) == quality)
    }

    @Test func sampleTimeDefaultsContinuousToMonotonic() throws {
        #expect(time.continuousNanos == time.monotonicNanos)
        let now = SampleTime.now()
        #expect(now.continuousNanos >= now.monotonicNanos, "连续时钟包含睡眠时间，不会小于 uptime")

        // 没有 continuousNanos 字段的旧数据按 monotonicNanos 解码
        let json = #"{"monotonicNanos":5,"wallClock":0}"#
        let decoded = try JSONDecoder().decode(SampleTime.self, from: Data(json.utf8))
        #expect(decoded.continuousNanos == 5)
    }

    @Test func sampleRoundTripsThroughCodable() throws {
        let samples = [
            Sample(id: .cpuUsageCore(3), value: 0.5, quality: .estimated, time: time),
            Sample.unavailable(.appSelfCPU, reason: .noElapsedTicks(), at: time),
        ]
        let data = try JSONEncoder().encode(samples)
        #expect(try JSONDecoder().decode([Sample].self, from: data) == samples)
    }

    @Test func decodingRejectsValueQualityMismatch() throws {
        // 可用的样本没有数值，或者不可用的样本带了数值，都是损坏的数据。
        let valid = try JSONEncoder().encode(Sample(id: .cpuUsageTotal, value: 0.5, time: time))
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["value"] = nil
        let missingValue = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Sample.self, from: missingValue)
        }

        let unavailable = try JSONEncoder().encode(
            Sample.unavailable(.cpuUsageTotal, reason: .readFailed(), at: time))
        var object2 = try #require(JSONSerialization.jsonObject(with: unavailable) as? [String: Any])
        object2["value"] = 0.0
        let extraValue = try JSONSerialization.data(withJSONObject: object2)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Sample.self, from: extraValue)
        }
    }

    @Test func selfTestResultPassesOnlyWhenAllChecksPass() {
        #expect(!SelfTestResult(checks: [], dataPath: "x").passed)
        let ok = SelfTestCheck(name: "a", passed: true, detail: "")
        let bad = SelfTestCheck(name: "b", passed: false, detail: "")
        #expect(SelfTestResult(checks: [ok, ok], dataPath: "x").passed)
        #expect(!SelfTestResult(checks: [ok, bad], dataPath: "x").passed)
    }

    @Test func widgetSnapshotRoundTrips() throws {
        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            samples: [Sample(id: .cpuUsageTotal, value: 0.1, time: time)])
        #expect(snapshot.version == WidgetSnapshot.currentVersion)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data) == snapshot)
        NoopSnapshotSink().write(snapshot)  // 默认实现什么都不做
    }
}
