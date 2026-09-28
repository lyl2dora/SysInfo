import IOKit
import IOKit.storage
var d = NVMeSMARTData()
print("NVMeSMARTData visible from Swift module IOKit: size=\(MemoryLayout<NVMeSMARTData>.size) key=\(kIOPropertyNVMeSMARTCapableKey)")
