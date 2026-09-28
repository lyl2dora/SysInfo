// thermalstate.swift - public coarse thermal signals: ProcessInfo.thermalState and the OSThermalNotification pressure level (notify API).
import Foundation
import Darwin
import notify
let ts = ProcessInfo.processInfo.thermalState
print("ProcessInfo.thermalState =", ts.rawValue, "(0 nominal,1 fair,2 serious,3 critical)")
var token: Int32 = 0
let name = "com.apple.system.thermalpressurelevel"   // kOSThermalNotificationPressureLevelName
if notify_register_check(name, &token) == NOTIFY_STATUS_OK {
    var state: UInt64 = 0
    notify_get_state(token, &state)
    print("\(name) state =", state, "(OSThermalPressureLevel: 0 nominal,1 moderate,2 heavy,3 trapping,4 sleeping)")
    notify_cancel(token)
}
