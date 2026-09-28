// Review probe: does CWWiFiClient.interface(withName:) return nil for a non-Wi-Fi BSD name (Stats readers.swift:309 branch)?
import Foundation
import CoreWLAN
for n in ["en0", "en1", "en2", "bogus9"] {
    let i = CWWiFiClient.shared().interface(withName: n)
    print("\(n): interface(withName:) = \(i == nil ? "nil" : "non-nil (name=\(i!.interfaceName ?? "nil") txRate=\(i!.transmitRate()) powerOn=\(i!.powerOn()))")")
}
