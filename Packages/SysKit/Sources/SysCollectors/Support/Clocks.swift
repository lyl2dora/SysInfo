// 采样耗时用到的时钟。

import Darwin

enum Clocks {
    /// 单调时钟，纳秒（`CLOCK_UPTIME_RAW`，与 `SampleTime.monotonicNanos` 同源）。
    static func uptimeNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// 当前线程已消耗的 CPU 时间，纳秒。
    static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }
}
