// wifi_cost.swift - CoreWLAN 读取开销（面板打开时才读，D10）：每秒一次读 rssi / noise / txRate / channel / phyMode / transmitPower，
// 记线程 CPU，20 轮中位数；只输出无需授权的字段，不读 SSID/BSSID。
// build: xcrun swiftc -O -o wifi_cost wifi_cost.swift -framework CoreWLAN
import CoreWLAN
import Foundation
func tc() -> Double { var ts = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return Double(ts.tv_sec) * 1e3 + Double(ts.tv_nsec) / 1e6 }
let t0 = tc(); let client = CWWiFiClient.shared(); let iface = client.interface(); let tInit = tc() - t0
guard let i = iface else { print("no wifi interface"); exit(0) }
print(String(format: "init(CWWiFiClient + interface) = %.3f ms", tInit))
var v: [Double] = []; var last = ""
for _ in 0..<20 {
    sleep(1)
    let a = tc()
    let r = i.rssiValue(), n = i.noiseMeasurement(), tx = i.transmitRate(), ch = i.wlanChannel(), phy = i.activePHYMode(), pw = i.transmitPower(), on = i.powerOn()
    v.append(tc() - a)
    last = "power=\(on) rssi=\(r) noise=\(n) txRate=\(tx) ch=\(ch?.channelNumber ?? -1) band=\(ch?.channelBand.rawValue ?? -1) width=\(ch?.channelWidth.rawValue ?? -1) phy=\(phy.rawValue) txPower=\(pw)"
}
v.sort()
print(String(format: "read(7 fields) median=%.3f ms p90=%.3f ms", v[10], v[18]))
print("last: \(last)")
