// mach 时间单位换算（M0 设计 §5.1、§8）。
//
// `rusage_info` 里的 CPU 时间是 mach absolute time 单位，不是纳秒；Apple 芯片上 numer/denom 目前是 125/3，
// 但这里一律用 `mach_timebase_info` 运行时读取，不写死（D20）。

import Darwin

struct MachTimebase: Hashable, Sendable {
    var numer: UInt32
    var denom: UInt32

    /// 本机的 timebase；读取失败或分母为 0 时为 nil。
    static let current: MachTimebase? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return nil }
        return MachTimebase(numer: info.numer, denom: info.denom)
    }()

    /// mach tick → 纳秒。用 128 位中间值，精确且不溢出；结果超出 UInt64 时饱和到 `UInt64.max`。
    func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        precondition(denom > 0, "timebase 分母不能为 0")
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < UInt64(denom) else { return .max }
        return UInt64(denom).dividingFullWidth(product).quotient
    }
}
