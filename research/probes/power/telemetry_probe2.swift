// telemetry_probe2.swift — AppleSmartBattery.PowerTelemetryData refreshes only every ~60 s.
// Sample 4 times, 62 s apart, and derive the per-minute average from accumulator deltas.
import Foundation
import IOKit

let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
guard svc != 0 else { print("AppleSmartBattery absent"); exit(1) }
func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
func telemetry() -> [String: Int] {
    guard let v = prop("PowerTelemetryData") as? [String: Any] else { return [:] }
    var out: [String: Int] = [:]; for (k, x) in v { if let n = x as? Int { out[k] = n } }; return out
}
var prev = telemetry()
var prevU = prop("UpdateTime") as? Int ?? 0
print("s0 UpdateTime=\(prevU) SystemPowerIn=\(prev["SystemPowerIn"]!) mW SystemLoad=\(prev["SystemLoad"]!) V=\(prev["SystemVoltageIn"]!) mV I=\(prev["SystemCurrentIn"]!) mA")
for i in 1...4 {
    Thread.sleep(forTimeInterval: 62)
    let cur = telemetry(); let u = prop("UpdateTime") as? Int ?? 0
    func d(_ k: String) -> Int { (cur[k] ?? 0) - (prev[k] ?? 0) }
    let n = d("SystemPowerInAccumulatorCount")
    print("s\(i) UpdateTime=\(u) (dU=\(u - prevU)s) SystemPowerIn=\(cur["SystemPowerIn"]!) mW V=\(cur["SystemVoltageIn"]!) mV I=\(cur["SystemCurrentIn"]!) mA SystemLoad=\(cur["SystemLoad"]!) Wall=\(cur["WallEnergyEstimate"]!) EffLoss=\(cur["AdapterEfficiencyLoss"]!) SysEnergyConsumed=\(cur["SystemEnergyConsumed"]!) | dCount=\(n) dAccSysPowerIn=\(d("AccumulatedSystemPowerIn")) avg=\(n > 0 ? d("AccumulatedSystemPowerIn") / n : -1) mW | dAccWall=\(d("AccumulatedWallEnergyEstimate")) dAccSysEnergy=\(d("AccumulatedSystemEnergyConsumed")) dAccEffLoss=\(d("AccumulatedAdapterEfficiencyLoss")) errCount=\(cur["PowerTelemetryErrorCount"]!)")
    prev = cur; prevU = u
}
IOObjectRelease(svc)
