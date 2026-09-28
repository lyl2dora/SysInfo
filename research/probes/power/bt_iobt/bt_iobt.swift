// bt_iobt.swift — child probe: does IOBluetoothDevice.pairedDevices() work without Bluetooth TCC?
// Launched by spawn_disclaim so THIS binary (Info.plist WITHOUT NSBluetoothAlwaysUsageDescription) is the
// responsible process: if the call is TCC-gated, TCC aborts us instead of showing a prompt to the user.
import Foundation
import CoreBluetooth
import IOBluetooth
setvbuf(stdout, nil, _IONBF, 0)
print("child pid=\(getpid()) bundleId=\(Bundle.main.bundleIdentifier ?? "nil") CBManager.authorization=\(CBManager.authorization.rawValue)")
print("calling IOBluetoothDevice.pairedDevices() ...")
let devs = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]
print("pairedDevices count=\(devs?.count ?? -1)")
func sel(_ d: IOBluetoothDevice, _ s: String) -> String {
    let sl = NSSelectorFromString(s)
    guard d.responds(to: sl) else { return "n/a" }
    let imp = d.method(for: sl)
    typealias F = @convention(c) (AnyObject, Selector) -> Int
    return "\(unsafeBitCast(imp, to: F.self)(d, sl))"
}
for d in devs ?? [] {
    print("- \(d.nameOrAddress ?? "?") addr=\(d.addressString ?? "?") paired=\(d.isPaired()) connected=\(d.isConnected()) rssi=\(d.rssi()) rawRSSI=\(d.rawRSSI()) classMajor=\(d.deviceClassMajor) recent=\(String(describing: d.recentAccessDate()))")
    for s in ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight", "batteryPercentCase", "headsetBattery", "isMultiBatteryDevice"] {
        print("    \(s) = \(sel(d, s))")
    }
}
let cs = NSSelectorFromString("connectedDevices")
if (IOBluetoothDevice.self as AnyObject).responds(to: cs), let r = (IOBluetoothDevice.self as AnyObject).perform(cs)?.takeUnretainedValue() as? [AnyObject] {
    print("private +connectedDevices count=\(r.count) \(r.compactMap { ($0 as? IOBluetoothDevice)?.nameOrAddress })")
}
print("done")
