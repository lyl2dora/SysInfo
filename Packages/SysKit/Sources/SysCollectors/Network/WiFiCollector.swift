// Wi-Fi 采集器 `network.wifi`（网络模块设计 §5.3，D60 N5、D10）：CoreWLAN，inline 通道。
//
// - 只在面板 Wi-Fi 卡片可见时有需求（5 s），后台不读；首次读时才创建 CWWiFiClient（2–4 ms）；
// - 只读无需授权的字段：RSSI、噪声、发送速率、信道 / 频段 / 带宽、PHY、发送功率原值；不读 SSID / BSSID，
//   不申请定位权限（D10、D22）；
// - 发送功率只进诊断页原值（M4 实测读出 1496 mW，不可信）；
// - 接口关闭或未关联（RSSI 为 0）时样本不可用。
//
// 自检（K19）：有 Wi-Fi 接口（提示：没有 Wi-Fi 的机器不算失败）。

import CoreWLAN
import Foundation
import Synchronization
import SysModel

public final class WiFiCollector: Collector {
    public static let collectorID: CollectorID = "network.wifi"
    public static let dataPath = "CoreWLAN CWInterface（RSSI、噪声、发送速率、信道，不读 SSID）"

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var latestInfo: WiFiInfo?
    }

    private let state = Mutex(State())
    /// CoreWLAN 对象只在引擎的串行队列（或 CLI 的线程）上使用。
    private nonisolated(unsafe) var client: CWWiFiClient?

    public init() {}

    /// 最近一次读到的非数值信息；没有 Wi-Fi 时为 nil。
    public var latestInfo: WiFiInfo? { state.withLock { $0.latestInfo } }

    private func interface() -> CWInterface? {
        if client == nil { client = CWWiFiClient.shared() }
        return client?.interface()
    }

    public func selfTest() -> SelfTestResult {
        let names = CWWiFiClient.shared().interfaceNames() ?? []
        return SelfTestResult(
            checks: [
                SelfTestCheck(
                    name: "network.wifi.interface", passed: !names.isEmpty, detail: "interfaces=\(names.count)", severity: .advisory)
            ], dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let ids: [MetricID] = [.networkWiFiRSSI, .networkWiFiNoise, .networkWiFiSNR, .networkWiFiTxRate]
        guard let interface = interface(), let name = interface.interfaceName else {
            state.withLock { $0.latestInfo = nil }
            return CollectorOutput(
                samples: ids.map { .unavailable($0, reason: .notSupported("no Wi-Fi interface"), at: time) }, status: .ok,
                dataPath: Self.dataPath)
        }
        let powerOn = interface.powerOn()
        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        let txRate = interface.transmitRate()
        let channel = interface.wlanChannel()
        let associated = powerOn && rssi != 0
        let info = WiFiInfo(
            interfaceName: name, powerOn: powerOn, channel: associated ? channel?.channelNumber : nil,
            bandGHz: associated ? channel.flatMap { Self.band($0.channelBand) } : nil,
            widthMHz: associated ? channel.flatMap { Self.width($0.channelWidth) } : nil,
            phyMode: associated ? Self.phy(interface.activePHYMode()) : nil,
            transmitPowerRaw: associated ? interface.transmitPower() : nil)
        state.withLock { $0.latestInfo = info }
        guard associated else {
            return CollectorOutput(
                samples: ids.map { .unavailable($0, reason: .notAssociated(), at: time) }, status: .ok, dataPath: Self.dataPath)
        }
        var samples = [
            Sample(id: .networkWiFiRSSI, value: Double(rssi), time: time),
            Sample(id: .networkWiFiNoise, value: Double(noise), time: time),
        ]
        if noise != 0 {
            samples.append(Sample(id: .networkWiFiSNR, value: Double(rssi - noise), time: time))
        } else {
            samples.append(.unavailable(.networkWiFiSNR, reason: .readFailed("noise=0"), at: time))
        }
        samples.append(
            txRate > 0
                ? Sample(id: .networkWiFiTxRate, value: txRate * 1e6, time: time)
                : .unavailable(.networkWiFiTxRate, reason: .readFailed("txRate=0"), at: time))
        return CollectorOutput(samples: samples, status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    static func band(_ band: CWChannelBand) -> Double? {
        switch band {
        case .band2GHz: 2.4
        case .band5GHz: 5
        case .band6GHz: 6
        default: nil
        }
    }

    static func width(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
    }

    /// PHY 模式名。SDK 的枚举到 11ax 为止；更新的模式（11be 的原始值 7）按原始值识别。
    static func phy(_ mode: CWPHYMode) -> String? {
        switch mode.rawValue {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "802.11n"
        case 5: "802.11ac"
        case 6: "802.11ax"
        case 7: "802.11be"
        default: nil
        }
    }
}
