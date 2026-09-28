// stats_replica.swift — replicate Stats' Battery UsageReader.read() (Modules/Battery/readers.swift:60-143) and
// Bluetooth cacheDevices()/pmsetAccessoryLevels()/profilerDevices() (Modules/Bluetooth/readers.swift) on this Mac,
// to see what Stats would actually display. SMC keys read via the smc_power binary output is not needed here:
// PPBR/TB1T/TB2T are absent (see smc_power.txt), PDTR present.
import Foundation
import IOKit
import IOKit.ps

// ---------- Battery UsageReader replica ----------
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
func gi(_ k: String) -> Int? { IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int }
func gb(_ k: String) -> Bool? { IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool }
func gd(_ k: String) -> Double? { IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double }
func gdict(_ k: String) -> [String: Any]? { IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] }
print("== Stats Battery.isAvailable() (main.swift:100-104): sources non-empty = \(!(IOPSCopyPowerSourcesList(IOPSCopyPowerSourcesInfo().takeRetainedValue()).takeRetainedValue() as Array).isEmpty)")
print("AppleSmartBattery service=\(service) BatteryInstalled=\(gb("BatteryInstalled").map { "\($0)" } ?? "nil")")
let psInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
let psList = IOPSCopyPowerSourcesList(psInfo).takeRetainedValue() as [CFTypeRef]
for ps in psList {
    guard let list = IOPSGetPowerSourceDescription(psInfo, ps).takeUnretainedValue() as? [String: Any] else { continue }
    let powerSource = list[kIOPSPowerSourceStateKey] as? String ?? "AC Power"
    let level = Double(list[kIOPSCurrentCapacityKey] as? Int ?? 0) / 100
    let batteryData = gdict("BatteryData")
    var designed = gi("DesignCapacity") ?? batteryData?["DesignCapacity"] as? Int ?? 1; if designed == 0 { designed = 1 }
    var maxCap = gi("AppleRawMaxCapacity") ?? gi("NominalChargeCapacity") ?? batteryData?["NominalChargeCapacity"] as? Int ?? batteryData?["FullChargeCapacity"] as? Int ?? 1; if maxCap == 0 { maxCap = 1 }
    let health = Int((Double(100 * maxCap) / Double(designed)).rounded(.toNearestOrEven))
    var acw = 0
    if let ad = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any], let w = ad[kIOPSPowerAdapterWattsKey] as? Int { acw = w }
    print("""
    Stats would report for source '\(list[kIOPSNameKey] ?? "?")' (Type=\(list[kIOPSTypeKey] ?? "?")):
      powerSource=\(powerSource) isBatteryPowered=\(powerSource == "Battery Power") isCharged=\(list[kIOPSIsChargedKey] as? Bool ?? false) isCharging(IOReg)=\(gb("IsCharging") ?? false)
      level=\(level) timeToEmpty=\(list[kIOPSTimeToEmptyKey] as? Int ?? 0) timeToCharge=\(list[kIOPSTimeToFullChargeKey] as? Int ?? 0)
      cycles=\(gi("CycleCount") ?? 0) currentCapacity=\(gi("AppleRawCurrentCapacity") ?? batteryData?["RemainingCapacity"] as? Int ?? 0) designed=\(designed) max=\(maxCap) health=\(health)%  <- bogus on a battery-less Mac
      current=\(gi("Amperage") ?? 0) voltage=\((gd("Voltage") ?? 0) / 1000) (IOPS UPS 'Voltage' \(list[kIOPSVoltageKey] ?? "nil") ignored) temperature(IOReg)=\(gd("Temperature").map { "\($0 / 100)" } ?? "nil -> 0")
      ACwatts=\(acw) AdapterDetails.AdapterVoltage=\(gdict("AdapterDetails")?["AdapterVoltage"] ?? "nil") ChargerData=\(gdict("ChargerData") == nil ? "nil" : "present")
    """)
}

// ---------- Bluetooth cacheDevices() replica (readers.swift:226-271) ----------
print("== Bluetooth cacheDevices(): UserDefaults(suiteName: /Library/Preferences/com.apple.Bluetooth)")
let cache = UserDefaults(suiteName: "/Library/Preferences/com.apple.Bluetooth")
print("  suite nil? \(cache == nil)  DeviceCache=\(cache?.object(forKey: "DeviceCache") == nil ? "nil" : "present") PairedDevices=\(cache?.object(forKey: "PairedDevices") == nil ? "nil" : "present") CoreBluetoothCache=\(cache?.object(forKey: "CoreBluetoothCache") == nil ? "nil" : "present")")
print("  keys present: \(cache?.dictionaryRepresentation().keys.filter { !$0.hasPrefix("NS") && !$0.hasPrefix("Apple") && !$0.hasPrefix("com.apple") }.sorted() ?? [])")

// ---------- pmsetAccessoryLevels() replica (readers.swift:383-437, standalone path 451-461) ----------
print("== Bluetooth pmsetAccessoryLevels(): pmset -g accps -xml")
let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); t.arguments = ["-g", "accps", "-xml"]
let pipe = Pipe(); t.standardOutput = pipe; try! t.run()
let res = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
let plists = res.components(separatedBy: "<?xml").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    .compactMap { try? PropertyListSerialization.propertyList(from: ("<?xml" + $0).data(using: .utf8)!, format: nil) as? [String: Any] }
for d in plists {
    guard let name = d["Name"] as? String, let cap = d["Current Capacity"] as? Int, let acc = d["Accessory Identifier"] as? String else { print("  skipped entry (guard)"); continue }
    let grouped = d["Group Identifier"] != nil
    print("  accepted entry: name='\(name)' cap=\(cap) accId='\(acc)' type=\(d["Type"] ?? "?") grouped=\(grouped) -> \(grouped ? "grouped (AirPods-style)" : "STANDALONE -> appended as BLEDevice(RSSI:100,isConnected:true) in Bluetooth module")")
}

// ---------- profilerDevices() replica (readers.swift:275-322) ----------
print("== Bluetooth profilerDevices(): system_profiler SPBluetoothDataType -json")
let t2 = Process(); t2.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler"); t2.arguments = ["SPBluetoothDataType", "-json"]
let p2 = Pipe(); t2.standardOutput = p2; let st = Date(); try! t2.run()
let data2 = p2.fileHandleForReading.readDataToEndOfFile(); t2.waitUntilExit()
print("  system_profiler took \(String(format: "%.2f", Date().timeIntervalSince(st)))s")
if let json = try? JSONSerialization.jsonObject(with: data2) as? [String: Any], let arr = json["SPBluetoothDataType"] as? [[String: Any]], let first = arr.first {
    let conn = first["device_connected"] as? [[String: [String: Any]]] ?? []
    print("  device_connected array elements=\(conn.count); Stats iterates only rawList.first -> \(conn.first?.keys.sorted() ?? [])")
    let nc = first["device_not_connected"] as? [[String: [String: String]]]
    print("  device_not_connected cast as [[String:[String:String]]] ok=\(nc != nil) count=\(nc?.count ?? 0); battery keys inside not_connected are ignored by Stats: \((first["device_not_connected"] as? [[String: [String: Any]]] ?? []).flatMap { $0.values.flatMap { $0.keys.filter { $0.contains("battery") } } })")
}
