// bt_methods.swift — ObjC runtime introspection only (no Bluetooth calls, no TCC): list battery-related
// selectors on IOBluetoothDevice and a few private Bluetooth framework classes.
import Foundation
import IOBluetooth
import ObjectiveC

func dump(_ clsName: String, filter: (String) -> Bool) {
    guard let cls: AnyClass = NSClassFromString(clsName) else { print("\(clsName): class not found"); return }
    for (label, c) in [("instance", cls), ("class", object_getClass(cls)!)] {
        var n: UInt32 = 0
        guard let ms = class_copyMethodList(c, &n) else { continue }
        let names = (0..<Int(n)).map { NSStringFromSelector(method_getName(ms[$0])) }.filter(filter).sorted()
        free(ms)
        print("\(clsName) [\(label)] \(names.count) matching: \(names)")
    }
}
let bat: (String) -> Bool = { $0.lowercased().contains("battery") || $0.lowercased().contains("paired") || $0.lowercased().contains("connected") && $0.count < 30 }
print("dlopen IOBluetooth = \(dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW) != nil)")
dump("IOBluetoothDevice", filter: bat)
for f in ["/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",
          "/System/Library/PrivateFrameworks/MobileBluetooth.framework/MobileBluetooth",
          "/System/Library/PrivateFrameworks/BluetoothServices.framework/BluetoothServices",
          "/System/Library/PrivateFrameworks/CoreBluetoothUI.framework/CoreBluetoothUI"] {
    print("dlopen(\(f)) = \(dlopen(f, RTLD_NOW) != nil ? "ok" : String(cString: dlerror()))")
}
for c in ["BluetoothManager", "BluetoothDevice", "BTSDevice", "BTDevice", "CBClassicPeripheral"] {
    dump(c, filter: { $0.lowercased().contains("battery") })
}
