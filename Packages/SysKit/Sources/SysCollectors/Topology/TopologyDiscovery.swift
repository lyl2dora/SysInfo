// 拓扑发现：读取设备树、sysctl、host_processor_info 和 IOReport，交给 TopologyResolver 判定（CPU 模块设计 §5.2）。
//
// 设备树里的 `logical-cpu-id`、`cluster-id`、`die-id`、`cluster-type`、`l2-cache-size` 是公开 API 读到的
// 未文档化属性（边界稿 §2.1「否（未文档键）」），不涉及私有符号。

import Foundation
import IOKit
import Synchronization
import SysModel

public enum TopologyReader {
    /// 读取全部输入。`tableTopByCluster` 由频率发现提供（第 3 步接入后传入）。
    public static func readInputs(tableTopByCluster: [ClusterKey: Double]? = nil) -> TopologyInputs {
        let levelCount = Int(SystemInfo.sysctlInt32("hw.nperflevels") ?? 0)
        let levels = (0..<max(levelCount, 0)).map { i in
            TopologyInputs.LevelInfo(
                name: SystemInfo.sysctlString("hw.perflevel\(i).name") ?? "perflevel\(i)",
                logicalCPUMax: Int(SystemInfo.sysctlInt32("hw.perflevel\(i).logicalcpu_max") ?? 0),
                cpusPerL2: Int(SystemInfo.sysctlInt32("hw.perflevel\(i).cpusperl2") ?? 0))
        }
        let hostCount = (try? CPULoadCollector.readTicks().get())?.count
        let coreChannels = IOReportHub.shared.channels(inGroup: "CPU Stats")?
            .filter { $0.key.subgroup == "CPU Core Performance States" }.count
        return TopologyInputs(
            dtCores: readDeviceTreeCores(), levels: levels, logicalCPUMax: SystemInfo.maxLogicalCPUCount,
            hostProcessorCount: hostCount, ioReportCoreChannelCount: coreChannels,
            tableTopByCluster: tableTopByCluster)
    }

    /// `IODeviceTree:/cpus` 下带 `logical-cpu-id` 的子节点。
    static func readDeviceTreeCores() -> [TopologyInputs.DTCore] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var cores: [TopologyInputs.DTCore] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let logicalID = integer(entry, "logical-cpu-id"), let cluster = integer(entry, "cluster-id") else {
                continue
            }
            cores.append(
                TopologyInputs.DTCore(
                    logicalID: Int(logicalID), die: UInt32(truncatingIfNeeded: integer(entry, "die-id") ?? 0),
                    cluster: UInt32(truncatingIfNeeded: cluster),
                    compatible: strings(entry, "compatible").first ?? "",
                    clusterType: strings(entry, "cluster-type").first ?? "",
                    l2Size: integer(entry, "l2-cache-size")))
        }
        return cores
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// 整数属性：CFNumber，或小端的 1/2/4/8 字节 CFData（设备树的常见写法）。
    static func integer(_ entry: io_registry_entry_t, _ key: String) -> UInt64? {
        guard let value = property(entry, key) else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            var out: Int64 = 0
            return CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &out) && out >= 0
                ? UInt64(out) : nil
        }
        guard CFGetTypeID(value) == CFDataGetTypeID() else { return nil }
        return littleEndianInteger(Data(referencing: unsafeDowncast(value, to: NSData.self)))
    }

    /// 字符串属性：NUL 分隔的 CFData（如 `compatible`）或 CFString。
    static func strings(_ entry: io_registry_entry_t, _ key: String) -> [String] {
        guard let value = property(entry, key) else { return [] }
        if CFGetTypeID(value) == CFStringGetTypeID() { return [unsafeDowncast(value, to: NSString.self) as String] }
        guard CFGetTypeID(value) == CFDataGetTypeID() else { return [] }
        return nulSeparatedStrings(Data(referencing: unsafeDowncast(value, to: NSData.self)))
    }

    static func littleEndianInteger(_ data: Data) -> UInt64? {
        guard [1, 2, 4, 8].contains(data.count) else { return nil }
        return data.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func nulSeparatedStrings(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }
}

/// 当前拓扑。启动、唤醒、系统 build 变化时由 `cpu.load` 的自检刷新（K19）。
public final class CPUTopologyService: Sendable {
    public static let shared = CPUTopologyService()

    private struct State {
        var topology: CPUTopology?
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())
    private let read: @Sendable () -> TopologyInputs

    init(read: @escaping @Sendable () -> TopologyInputs = { CPUTopologyService.readWithFrequencyEvidence() }) {
        self.read = read
    }

    /// 读取输入，并补上频率依据：先按设备树分簇，再为每簇找 DVFS 表顶（频率发现不需要 perflevel，只需要簇）。
    static func readWithFrequencyEvidence() -> TopologyInputs {
        var inputs = TopologyReader.readInputs()
        let preliminary = TopologyResolver.resolve(inputs)
        guard !preliminary.clusters.isEmpty else { return inputs }
        let tops = FrequencyPlan.discover(clusters: preliminary.clusters, logicalCPUCount: preliminary.logicalCPUCount)
            .tableTops
        if tops.count == preliminary.clusters.count { inputs.tableTopByCluster = tops }
        return inputs
    }

    /// 最近一次发现的拓扑；还没发现过时为 nil。
    public var current: CPUTopology? { state.withLock { $0.topology } }

    /// 拓扑每变化一次加 1，消费者据此判断要不要重建缓存。
    public var generation: UInt64 { state.withLock { $0.generation } }

    /// 重新发现。结果与上次不同时 `generation` 加 1。
    @discardableResult
    public func refresh() -> CPUTopology {
        let topology = TopologyResolver.resolve(read())
        state.withLock { s in
            if s.topology != topology {
                s.topology = topology
                s.generation += 1
            }
        }
        return topology
    }
}
