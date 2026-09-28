// sp_parse_replica.swift — replicate Stats Modules/Bluetooth/readers.swift:288-305 parse on a live system_profiler JSON
// to confirm whether only the first connected device is taken.
import Foundation
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
let arr = json["SPBluetoothDataType"] as! [[String: Any]]
let d = arr.first!
let raw = d["device_connected"] as? [[String: [String: Any]]]
print("device_connected elements: \(raw?.count ?? -1) -> names \(raw?.flatMap { $0.keys } ?? [])")
if let rawList = raw, let devices = rawList.first {
    print("Stats iterates rawList.first only -> \(devices.keys.sorted())")
}
