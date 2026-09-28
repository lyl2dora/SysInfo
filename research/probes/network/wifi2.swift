// Probe: what non-location-gated CoreWLAN data leaks the current network identity (evaluates Stats' networkProfiles fallback).
import Foundation
import CoreWLAN
func p(_ s: String) { print(s); fflush(stdout) }
guard let i = CWWiFiClient.shared().interface() else { exit(0) }
if let last = (i as NSObject).value(forKey: "lastNetworkJoined") as? CWNetwork {
    p("lastNetworkJoined ssid=\(last.ssid ?? "nil") bssid=\(last.bssid ?? "nil") rssi=\(last.rssiValue) ch=\(last.wlanChannel?.channelNumber ?? -1)")
}
if let cfg = i.configuration() {
    for (n, obj) in cfg.networkProfiles.enumerated() {
        guard let prof = obj as? CWNetworkProfile else { continue }
        // only print index, SSID length and security to avoid dumping the user's saved network names
        p("profile[\(n)] ssidLen=\(prof.ssid?.count ?? -1) security=\(prof.security.rawValue)\(n == 0 ? " ssid=\(prof.ssid ?? "nil")" : "")")
    }
}
p("current security=\(i.security().rawValue) (11=WPA3 Personal, 13=WPA3 Transition)")
if let s = i.cachedScanResults() {
    let onCurrentChannel = s.filter { $0.wlanChannel?.channelNumber == i.wlanChannel()?.channelNumber }
    p("scan results on current channel=\(onCurrentChannel.count) ssids=\(onCurrentChannel.map { $0.ssid ?? "nil" }) bssids=\(onCurrentChannel.map { $0.bssid ?? "nil" })")
}
