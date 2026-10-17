// resource coalition 的 Swift 封装（CPU 模块设计 §3、§5.7；边界稿 §2.5、§7.4）。
//
// 槽位含义（27.0 实测，400 字节 = 50 个 UInt64）：
// - 0 / 1：tasks_started / tasks_exited（残差归因前判断窗口内成员有没有变化）；
// - 11：能耗，nJ；
// - 22：在 perflevel0 上的 CPU 时间（mach tick）；
// - 23：cpu_time_eqos_len，必须等于 7（自检 S3）；
// - 24–30：按 QoS 拆分的 CPU 时间（mach tick），之和就是总 CPU 时间。不用 slot 3；
// - 31 / 32：instructions / cycles；35 / 36：perflevel0 上的 instructions / cycles；
// - 4 / 5：中断唤醒 / 空闲（package）唤醒次数（slot 5 与 `top IDLEW` 522/522 相等，调研报告 §1.8）；
// - 40：phys_footprint；49：pageins（与成员 rusage_info_v6 逐位相等，自检 S4，processes/coal_check.c）。
// 结构体以后可能在尾部追加字段，所以缓冲给 512 字节，自检只要求「写出 ≥400 字节」，不做等值判断。

internal import CSysPrivate
import Darwin

/// `proc_listcoalitions` 的一项。
public struct CoalitionEntry: Hashable, Sendable {
    public var id: UInt64
    public var type: UInt32
    /// 当前成员数。常驻的 launchd job 可能为 0。
    public var tasks: UInt32
}

/// 一个 coalition 的资源用量槽位。
public struct CoalitionUsage: Hashable, Sendable {
    public static let bufferSlots = 64
    public static let minimumBytes = 400
    public static let expectedEQoSLength: UInt64 = 7

    /// 原始槽位（`bufferSlots` 个；超出内核实际写出长度的部分为 0）。
    public var slots: [UInt64]

    public init(slots: [UInt64]) {
        self.slots = slots
    }

    private func slot(_ index: Int) -> UInt64 { index < slots.count ? slots[index] : 0 }

    public var tasksStarted: UInt64 { slot(0) }
    public var tasksExited: UInt64 { slot(1) }
    /// 累计唤醒次数：中断唤醒（槽位 4）+ 空闲唤醒（槽位 5）（应用活动的「唤醒」列，D67）。
    public var wakeups: UInt64 { slot(4) &+ slot(5) }
    /// 累计磁盘读 / 写字节（6、7 号槽，含 root 成员；存储模块设计 §4.5，调研报告 disk-review/coal_validate）。
    public var diskBytesRead: UInt64 { slot(6) }
    public var diskBytesWritten: UInt64 { slot(7) }
    /// GPU 时间，纳秒（slot 8，与 Metal 自报的命令缓冲执行时间吻合，调研报告 §1.8）。
    public var gpuNanos: UInt64 { slot(8) }
    /// ANE 时间，mach tick（slot 38，饱和测试推定；GPU 边界稿 §1.3 两台换算后都不超过 100%）。
    public var aneTicks: UInt64 { slot(38) }
    /// ANE 能耗，nJ（slot 39；全部 coalition 之和 ÷ PMGR ANE 批次 = 0.92–0.93，D58）。
    public var aneEnergyNanojoules: UInt64 { slot(39) }
    /// GPU 能耗，nJ（slot 41；全部 coalition 之和与 AGX「GPU Energy」逐焦耳相等）。
    public var gpuEnergyNanojoules: UInt64 { slot(41) }
    public var energyNanojoules: UInt64 { slot(11) }
    public var perfLevel0Ticks: UInt64 { slot(22) }
    public var instructions: UInt64 { slot(31) }
    public var cycles: UInt64 { slot(32) }
    /// perflevel0 上的 cycles（与 22 号槽的 perflevel0 CPU 时间配对，得到 perflevel0 的平均频率）。
    public var perfLevel0Cycles: UInt64 { slot(36) }
    public var physFootprint: UInt64 { slot(40) }
    public var pageins: UInt64 { slot(49) }
    public var eqosLength: UInt64 { slot(23) }
    /// 总 CPU 时间（mach tick）：槽 24–30 之和，溢出时饱和。
    public var cpuTicks: UInt64 {
        (24...30).reduce(UInt64(0)) { sum, index in
            let (value, overflow) = sum.addingReportingOverflow(slot(index))
            return overflow ? .max : value
        }
    }
}

/// resource coalition 的只读访问。无状态，可以在任何线程调用。
public enum CoalitionReader {
    /// 三个私有符号都解析到（自检 S1）。
    public static var isAvailable: Bool { csp_coal_available() != 0 }

    /// 列出全部 resource coalition；不可用或失败时返回 nil。
    public static func list() -> [CoalitionEntry]? {
        let entrySize = MemoryLayout<csp_coal_entry>.stride
        // 两次调用之间可能新建 coalition：先问大小，再留出余量；写满时说明可能被截断，加倍重试。
        let needed = csp_coal_list(nil, 0)
        guard needed > 0 else { return nil }
        var capacity = Int(needed) / entrySize + 64
        for _ in 0..<4 {
            var buffer = [csp_coal_entry](repeating: csp_coal_entry(), count: capacity)
            let written = buffer.withUnsafeMutableBufferPointer { b in
                csp_coal_list(b.baseAddress, Int32(capacity * entrySize))
            }
            guard written >= 0 else { return nil }
            let count = Int(written) / entrySize
            if count < capacity {
                return buffer.prefix(count).map {
                    CoalitionEntry(id: $0.coalition_id, type: $0.type, tasks: $0.tasks)
                }
            }
            capacity *= 2
        }
        return nil
    }

    /// 读资源用量；失败（例如 coalition 刚消失）时返回 nil。
    public static func usage(of id: UInt64) -> CoalitionUsage? {
        var slots = [UInt64](repeating: 0, count: CoalitionUsage.bufferSlots)
        let rc = slots.withUnsafeMutableBytes { b in
            csp_coal_resource_usage(id, b.baseAddress!, b.count)
        }
        return rc == 0 ? CoalitionUsage(slots: slots) : nil
    }

    /// 自检 S3：读资源用量，并探测内核实际写出的字节数。
    public static func probeUsage(of id: UInt64) -> (usage: CoalitionUsage, bytesWritten: Int)? {
        var slots = [UInt64](repeating: 0, count: CoalitionUsage.bufferSlots)
        var written = 0
        let rc = slots.withUnsafeMutableBytes { b in
            csp_coal_resource_usage_probe(id, b.baseAddress!, b.count, &written)
        }
        guard rc == 0 else { return nil }
        // 探测时用哨兵字节填满了缓冲，超出写出长度的部分清零，避免哨兵值被当成数据。
        let validSlots = written / MemoryLayout<UInt64>.size
        for index in validSlots..<slots.count { slots[index] = 0 }
        return (CoalitionUsage(slots: slots), written)
    }

    /// 成员 pid 列表。缓冲按 `tasksHint + 16` 分配；写满时可能被截断，加倍重试（边界稿 §7.4）。
    public static func members(of id: UInt64, tasksHint: Int) -> [pid_t]? {
        var capacity = max(tasksHint, 0) + 16
        for _ in 0..<6 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            var size = capacity * MemoryLayout<pid_t>.stride
            let rc = buffer.withUnsafeMutableBufferPointer { b in
                csp_coal_pid_list(id, b.baseAddress!, &size)
            }
            guard rc == 0 else { return nil }
            let count = size / MemoryLayout<pid_t>.stride
            if count < capacity { return Array(buffer.prefix(count)) }
            capacity *= 2
        }
        return nil
    }

    /// 进程所在的 resource coalition id。
    public static func coalition(ofPID pid: pid_t) -> UInt64? {
        var id: UInt64 = 0
        return csp_coal_of_pid(pid, &id) == 0 && id != 0 ? id : nil
    }
}

/// proc_pidinfo 私有 flavor 的封装（CPU 模块设计 §3）。
public enum ProcessPrivateInfo {
    /// 线程在某个 perflevel 上的计数。
    public struct LevelCounts: Hashable, Sendable {
        public var instructions: UInt64
        public var cycles: UInt64
        public var userTimeTicks: UInt64
        public var systemTimeTicks: UInt64
        public var energyNanojoules: UInt64

        public init(
            instructions: UInt64, cycles: UInt64, userTimeTicks: UInt64, systemTimeTicks: UInt64, energyNanojoules: UInt64
        ) {
            self.instructions = instructions
            self.cycles = cycles
            self.userTimeTicks = userTimeTicks
            self.systemTimeTicks = systemTimeTicks
            self.energyNanojoules = energyNanojoules
        }
    }

    /// 本进程线程 `threadID`（`pthread_threadid_np`）按 perflevel 拆分的计数，下标即 perflevel。
    /// 只用于 `sysinfo-cli verify` 和自检的被动校验，不进常规采样。
    public static func threadCounts(threadID: UInt64, maxLevels: Int = 8) -> [LevelCounts]? {
        var levels = [csp_thread_counts_level](repeating: csp_thread_counts_level(), count: max(maxLevels, 1))
        let n = levels.withUnsafeMutableBufferPointer { b in
            csp_thread_counts(getpid(), threadID, b.baseAddress!, Int32(b.count))
        }
        guard n > 0 else { return nil }
        return levels.prefix(Int(n)).map {
            LevelCounts(
                instructions: $0.instructions, cycles: $0.cycles, userTimeTicks: $0.user_time_mach,
                systemTimeTicks: $0.system_time_mach, energyNanojoules: $0.energy_nj)
        }
    }

    /// 进程的开机期间唯一 id（不复用），名称和图标缓存用它做键。
    public static func uniqueID(of pid: pid_t) -> UInt64? {
        var id: UInt64 = 0
        return csp_proc_unique_id(pid, &id) == 0 ? id : nil
    }
}
