// Probe: CoreWLAN details on macOS 27 without Location Services grant; plus Stats' fallbacks.
import Foundation
import CoreWLAN
import CoreLocation

func p(_ s: String) { print(s); fflush(stdout) }

let lm = CLLocationManager()
let st = lm.authorizationStatus
p("CLLocationManager.authorizationStatus=\(st.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorizedAlways) servicesEnabled=\(CLLocationManager.locationServicesEnabled())")

let client = CWWiFiClient.shared()
p("interfaceNames=\(CWWiFiClient.interfaceNames() ?? [])")
guard let i = client.interface() else { p("no default Wi-Fi interface"); exit(0) }

func dump(_ tag: String) {
    p("--- \(tag)")
    p("name=\(i.interfaceName ?? "nil") powerOn=\(i.powerOn()) serviceActive=\(i.serviceActive()) mode=\(i.interfaceMode().rawValue)")
    p("ssid=\(i.ssid() ?? "nil") ssidData=\(i.ssidData().map { "\($0.count)B" } ?? "nil") bssid=\(i.bssid() ?? "nil")")
    p("rssi=\(i.rssiValue()) dBm noise=\(i.noiseMeasurement()) dBm SNR=\(i.rssiValue() - i.noiseMeasurement()) dB")
    p("txRate=\(i.transmitRate()) Mbps txPower=\(i.transmitPower()) mW phyMode=\(i.activePHYMode().rawValue) (7=11be,6=11ax,5=11ac)")
    if let ch = i.wlanChannel() {
        p("channel=\(ch.channelNumber) band=\(ch.channelBand.rawValue) (1=2G,2=5G,3=6G) width=\(ch.channelWidth.rawValue) (1=20,2=40,3=80,4=160)")
    } else { p("channel=nil") }
    p("security=\(i.security().rawValue) countryCode=\(i.countryCode() ?? "nil") hwAddress=\(i.hardwareAddress() ?? "nil")")
    if let cfg = i.configuration() {
        let profiles = cfg.networkProfiles
        p("configuration.networkProfiles.count=\(profiles.count) first.ssid=\((profiles.firstObject as? CWNetworkProfile)?.ssid ?? "nil")")
    } else { p("configuration=nil") }
    // KVC-only / private keys sometimes present
    for key in ["lastNetworkJoined", "cachedScanResults"] {
        let v = (i as NSObject).value(forKey: key)
        p("KVC \(key)=\(v.map { String(describing: type(of: $0)) } ?? "nil")")
    }
    if let cached = i.cachedScanResults() {
        let withSSID = cached.filter { $0.ssid != nil }.count
        p("cachedScanResults=\(cached.count) withSSID=\(withSSID) sampleRSSI=\(cached.prefix(3).map { $0.rssiValue })")
    } else { p("cachedScanResults=nil") }
}

dump("sample 1")
Thread.sleep(forTimeInterval: 2)
dump("sample 2")

// Event monitoring registration (Stats readers.swift:627-633 uses .ssidDidChange)
class D: NSObject, CWEventDelegate {
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        p("EVENT linkQuality if=\(interfaceName) rssi=\(rssi) tx=\(transmitRate)")
    }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { p("EVENT ssidDidChange \(interfaceName)") }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { p("EVENT bssidDidChange \(interfaceName)") }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { p("EVENT linkDidChange \(interfaceName)") }
}
let d = D()
client.delegate = d
for ev: CWEventType in [.ssidDidChange, .bssidDidChange, .linkDidChange, .linkQualityDidChange, .powerDidChange, .modeDidChange, .countryCodeDidChange] {
    do { try client.startMonitoringEvent(with: ev); p("startMonitoringEvent(\(ev.rawValue)) ok") }
    catch { p("startMonitoringEvent(\(ev.rawValue)) error=\(error)") }
}
RunLoop.main.run(until: Date().addingTimeInterval(8))
try? client.stopMonitoringAllEvents()
