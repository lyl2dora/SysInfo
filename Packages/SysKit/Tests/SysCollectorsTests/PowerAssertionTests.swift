// 电源断言的解析与合并（D69）。不访问硬件。

import Foundation
import Testing
@testable import SysCollectors
import SysModel

@Suite struct PowerAssertionTests {
    private func raw(_ pid: Int32, _ type: String, _ name: String, behalf: Int32? = nil, process: String = "p", start: Double? = nil)
        -> PowerAssertionCollector.RawAssertion
    {
        .init(
            pid: pid, onBehalfOf: behalf, processName: process, type: type, name: name,
            start: start.map(Date.init(timeIntervalSince1970:)))
    }

    @Test func mergesDuplicatesAndKeepsEarliestStart() {
        let merged = PowerAssertionCollector.merge(
            [raw(10, "UserIsActive", "remote", start: 50), raw(10, "UserIsActive", "remote", start: 20), raw(10, "UserIsActive", "remote")],
            ownPID: 1)
        #expect(merged.count == 1)
        #expect(merged[0].count == 3)
        #expect(merged[0].since == Date(timeIntervalSince1970: 20))
        #expect(merged[0].kind == .other)
    }

    @Test func onBehalfAssertionsBelongToTheTarget() {
        let merged = PowerAssertionCollector.merge(
            [raw(200, "PreventUserIdleSystemSleep", "audio", behalf: 300, process: "coreaudiod")], ownPID: 1)
        #expect(merged[0].pid == 300)
        #expect(merged[0].holderPID == 200)
        #expect(merged[0].isOnBehalf)
        #expect(merged[0].kind == .preventSleep)
    }

    @Test func dropsOwnSelfTestAssertion() {
        let merged = PowerAssertionCollector.merge(
            [
                raw(7, "PreventUserIdleDisplaySleep", PowerAssertionCollector.selfTestAssertionName),
                raw(7, "PreventUserIdleDisplaySleep", "real"),
            ], ownPID: 7)
        #expect(merged.map(\.name) == ["real"])
        #expect(merged[0].kind == .preventDisplaySleep)
    }

    @Test func dropsRunningboardLaunchBookkeeping() {
        let merged = PowerAssertionCollector.merge(
            [
                raw(652, "PreventUserIdleSystemSleep", "app<application.zone.lyl.sysinfo.dev.1.2(501)>652-1191-381351:FBApplicationProcess", behalf: 900, process: "runningboardd"),
                raw(652, "PreventUserIdleSystemSleep", "other", process: "runningboardd"),
            ], ownPID: 1)
        #expect(merged.map(\.name) == ["other"])
    }

    @Test func parsesIOPMDictionary() {
        let item: NSDictionary = [
            "AssertType": "NoIdleSleepAssertion", "AssertionTrueType": "PreventUserIdleSystemSleep", "AssertName": "Electron",
            "Process Name": "ExampleApp", "AssertStartWhen": Date(timeIntervalSince1970: 5),
        ]
        let behalf: NSDictionary = [
            "AssertionTrueType": "PreventUserIdleSystemSleep", "AssertName": "x", "AssertionOnBehalfOfPID": NSNumber(value: 42),
        ]
        let parsed = PowerAssertionCollector.parse([NSNumber(value: 9): [item], NSNumber(value: 10): [behalf]] as NSDictionary)
            .sorted { $0.pid < $1.pid }
        #expect(parsed.count == 2)
        #expect(parsed[0].type == "PreventUserIdleSystemSleep")
        #expect(parsed[0].processName == "ExampleApp")
        #expect(parsed[0].start == Date(timeIntervalSince1970: 5))
        #expect(parsed[1].onBehalfOf == 42)
    }

    @Test func categoriesFollowKindAndBundle() {
        let row = AppActivityRow(
            id: "c1", key: "k", name: "n", appPath: nil, isApp: false,
            assertions: [PowerAssertion(pid: 1, holderPID: 1, holderName: "n", type: "PreventSystemSleep", name: "x")])
        #expect(row.matches(.preventingSleep))
        #expect(row.matches(.background))
        #expect(!row.matches(.apps))
    }
}
