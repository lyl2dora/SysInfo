// 主 app 与小组件扩展共用（两个 target 都编进去）：组容器的位置、快照与「想要数据」标记的读写（规格 §3、§4.1）。
// 组名从各自 Info.plist 的 SysInfoAppGroup 读（由 xcconfig 的 SYSINFO_APP_GROUP 填入），代码里不拼。

import Foundation
import SysModel

enum WidgetStorage {
    static var appGroup: String? { Bundle.main.object(forInfoDictionaryKey: "SysInfoAppGroup") as? String }

    /// 组容器；没有 App Group（ad-hoc 签名的构建）时为 nil，小组件功能整体不可用。
    static var containerURL: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var snapshotURL: URL? { containerURL?.appendingPathComponent(WidgetSnapshot.fileName) }
    static var wantedMarkerURL: URL? { containerURL?.appendingPathComponent(WidgetSnapshot.wantedMarkerName) }

    static func readSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    /// 原子写入。
    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = snapshotURL else { throw CocoaError(.fileNoSuchFile) }
        try snapshot.encoded().write(to: url, options: .atomic)
    }

    /// 扩展：快照缺失或陈旧时留个标记，主 app 下次检查时立刻补写。
    static func markWanted(at date: Date = Date()) {
        guard let url = wantedMarkerURL else { return }
        try? Data(String(date.timeIntervalSince1970).utf8).write(to: url, options: .atomic)
    }

    /// 主 app：读出并删掉标记，返回标记的时间。
    static func takeWanted() -> Date? {
        guard let url = wantedMarkerURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return String(data: data, encoding: .utf8).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }
}
