// Probe: does SCDynamicStore State:/Network/Interface/<wifi>/AirPort leak SSID/BSSID without Location authorization?
import Foundation
import SystemConfiguration
import CoreWLAN
func p(_ s: String) { print(s); fflush(stdout) }
let wifi = CWWiFiClient.shared().interface()?.interfaceName ?? "en1"
guard let d = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(wifi)/AirPort" as CFString) as? [String: Any] else { p("nil"); exit(0) }
for (k, v) in d.sorted(by: { $0.key < $1.key }) {
    var desc: String
    if let data = v as? Data { desc = "Data(\(data.count)B) hex=\(data.map { String(format: "%02x", $0) }.joined(separator: ":"))" + (k == "SSID" ? " utf8=\(String(data: data, encoding: .utf8) ?? "?")" : "") }
    else if let s = v as? String { desc = "String(\(s.count)) \"\(s)\"" }
    else { desc = "\(v)" }
    p("\(k) = \(desc)")
}
p("CoreWLAN ssid()=\(CWWiFiClient.shared().interface()?.ssid() ?? "nil") bssid()=\(CWWiFiClient.shared().interface()?.bssid() ?? "nil")")
