// Review probe: is NVMeSMARTData reachable from Swift via the IOKit module alone (no bridging header)?
import IOKit
import IOKit.storage
let d = NVMeSMARTData()
print(MemoryLayout<NVMeSMARTData>.size)
