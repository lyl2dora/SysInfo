// telemetry_probe.swift — sample AppleSmartBattery.PowerTelemetryData (present even on a battery-less Mac mini)
// several times and check that the instantaneous/accumulated values move.
import Foundation
import IOKit

let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
guard svc != 0 else { print("AppleSmartBattery absent"); exit(1) }

func telemetry() -> [String: Int] {
    guard let v = IORegistryEntryCreateCFProperty(svc, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return [:] }
    var out: [String: Int] = [:]
    for (k, x) in v { if let n = x as? Int { out[k] = n } }
    return out
}
func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }

var prev = telemetry()
var prevT = Date()
print("t0 UpdateTime=\(prop("UpdateTime") ?? "nil") BatteryInstalled=\(prop("BatteryInstalled") ?? "nil") ExternalConnected=\(prop("ExternalConnected") ?? "nil")")
print("t0 SystemPowerIn=\(prev["SystemPowerIn"] ?? -1) mW  SystemVoltageIn=\(prev["SystemVoltageIn"] ?? -1) mV  SystemCurrentIn=\(prev["SystemCurrentIn"] ?? -1) mA  SystemLoad=\(prev["SystemLoad"] ?? -1)  WallEnergyEstimate=\(prev["WallEnergyEstimate"] ?? -1)  AdapterEfficiencyLoss=\(prev["AdapterEfficiencyLoss"] ?? -1)")
for i in 1...6 {
    Thread.sleep(forTimeInterval: 5)
    let cur = telemetry()
    let now = Date()
    let dt = now.timeIntervalSince(prevT)
    let v = Double(cur["SystemVoltageIn"] ?? 0) / 1000, a = Double(cur["SystemCurrentIn"] ?? 0) / 1000
    let dAcc = (cur["AccumulatedSystemPowerIn"] ?? 0) - (prev["AccumulatedSystemPowerIn"] ?? 0)
    let dCnt = (cur["SystemPowerInAccumulatorCount"] ?? 0) - (prev["SystemPowerInAccumulatorCount"] ?? 0)
    let dWall = (cur["AccumulatedWallEnergyEstimate"] ?? 0) - (prev["AccumulatedWallEnergyEstimate"] ?? 0)
    let dEnergy = (cur["AccumulatedSystemEnergyConsumed"] ?? 0) - (prev["AccumulatedSystemEnergyConsumed"] ?? 0)
    print(String(format: "t%d (+%.1fs) UpdateTime=%@ SystemPowerIn=%d mW | V*I=%.2f W | SystemLoad=%d | WallEnergyEstimate=%d | AdapterEffLoss=%d | dAccSysPowerIn=%d over %d samples (avg %.0f mW) | dAccWallEnergy=%d | dAccSysEnergy=%d",
                 i, dt, "\(prop("UpdateTime") ?? "nil")", cur["SystemPowerIn"] ?? -1, v * a, cur["SystemLoad"] ?? -1, cur["WallEnergyEstimate"] ?? -1, cur["AdapterEfficiencyLoss"] ?? -1,
                 dAcc, dCnt, dCnt > 0 ? Double(dAcc) / Double(dCnt) : -1, dWall, dEnergy))
    prev = cur; prevT = now
}
print("full last sample: \(telemetry().sorted { $0.key < $1.key })")
IOObjectRelease(svc)
