// 电源设备的历史（电源设备设计 §5，D84 PD6）：UPS 由电池供电的区间。
//
// 写法同电源断言：转为电池供电时开一行，转回外接电源时收尾；退出、停止记录时收尾；启动时把上次运行遗留的行
// 按上次提交的时刻收尾并标「估计」。过期清理沿用分钟表的保留期。

import Foundation

/// UPS 由电池供电的一段。
public struct UPSPowerSpan: Hashable, Sendable, Codable {
    public var start: Date
    /// 还在电池供电时为 nil。
    public var end: Date?
    /// 结束时刻是估计的（app 退出或崩溃时还没恢复外接电源）。
    public var endEstimated: Bool

    public init(start: Date, end: Date?, endEstimated: Bool = false) {
        self.start = start
        self.end = end
        self.endEstimated = endEstimated
    }
}

extension HistoryStore {
    /// 记一段电池供电的开始，返回行 id。
    public func openUPSSpan(start: Date) throws -> Int64 {
        try db.statement("INSERT INTO ups_power_span(start_s) VALUES(?)").run([.double(start.timeIntervalSince1970)])
        return db.lastInsertRowID
    }

    /// 记一段的结束。
    public func closeUPSSpan(id: Int64, end: Date, estimated: Bool = false) throws {
        try db.statement("UPDATE ups_power_span SET end_s = MAX(start_s, ?), end_estimated = ? WHERE id = ? AND end_s IS NULL")
            .run([.double(end.timeIntervalSince1970), .int(estimated ? 1 : 0), .int(id)])
    }

    /// 把所有未结束的行按 `end` 收尾，标「估计」。
    public func closeOpenUPSSpans(end: Date) throws {
        try db.statement("UPDATE ups_power_span SET end_s = MAX(start_s, ?), end_estimated = 1 WHERE end_s IS NULL")
            .run([.double(end.timeIntervalSince1970)])
    }

    /// 与 [from, to) 重叠的区间，按开始时刻排序。
    public func upsPowerSpans(from: Date, to: Date) throws -> [UPSPowerSpan] {
        try db.statement(
            "SELECT start_s, end_s, end_estimated FROM ups_power_span WHERE start_s < ? AND (end_s IS NULL OR end_s > ?) ORDER BY start_s"
        ).query([.double(to.timeIntervalSince1970), .double(from.timeIntervalSince1970)]) {
            UPSPowerSpan(
                start: Date(timeIntervalSince1970: $0.double(0)), end: $0.optionalDouble(1).map(Date.init(timeIntervalSince1970:)),
                endEstimated: $0.int(2) != 0)
        }
    }
}
