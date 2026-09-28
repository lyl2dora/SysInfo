// bt_auth.swift — query Bluetooth TCC state WITHOUT creating a CBCentralManager (so no permission prompt).
import Foundation
import CoreBluetooth
print("CBManager.authorization (class) = \(CBManager.authorization.rawValue)  (0 notDetermined, 1 restricted, 2 denied, 3 allowedAlways)")
print("Bundle.main.bundleIdentifier = \(Bundle.main.bundleIdentifier ?? "nil"), NSBluetoothAlwaysUsageDescription = \(Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") ?? "nil")")
