// 存储模块的数据模型（存储模块设计 §3，D54）。指标命名一旦发布就不改。
//
// - 以物理盘为单位（D54）：SMART、温度、读写都按盘；容量与 RAID 状态挂在「容量组」与「RAID 组」上；
// - 盘与组的键是本地加盐哈希（`DiskKey`），不含序列号等设备唯一标识（CLAUDE.md）；
// - 字节一律是字节，容量与速率按 1000 换算显示（K24，与访达一致）；温度 °C；比例 0…1。

/// 物理盘或 RAID 组的稳定键：本地加盐 SHA-256 的前 6 字节，12 位小写十六进制（存储模块设计 §3.1）。
public struct DiskKey: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 只接受 12 位十六进制（从 MetricID 里解析时用）。
    public init?(validating raw: some StringProtocol) {
        guard raw.count == 12, raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.rawValue = String(raw).lowercased()
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension MetricID {
    private static let diskPrefix = "storage.disk."
    private static let groupPrefix = "storage.group."

    /// 每块物理盘的指标。
    public enum DiskMetric: String, Sendable, CaseIterable {
        /// 读速率，B/s（驱动 Statistics 差分）。
        case read
        /// 写速率，B/s。
        case write
        /// 读 IOPS，1/s。
        case readOps
        /// 写 IOPS，1/s。
        case writeOps
        /// 平均读延迟，s：Δ总读时间 ÷ Δ读次数。区间内没有读时不可用。
        case readLatency
        /// 平均写延迟，s。
        case writeLatency
        /// SMART 综合温度，°C。
        case temp
        /// 已用寿命（Percentage Used），比例；厂商允许超过 1。
        case life
        /// 可用备用块，比例。
        case spare
        /// 介质与数据完整性错误，次（累计）。
        case mediaErrors
        /// critical warning 字节（位域，0 为无警告）。
        case warning
        /// 累计读取量，B（SMART 数据单元 × 512 000）。
        case dataRead
        /// 累计写入量，B。
        case dataWritten
    }

    /// 每个容量组的指标。
    public enum GroupMetric: String, Sendable, CaseIterable {
        /// 总量，B。
        case total
        /// 可用，B（`statfs`，同一 APFS 容器内的卷共享）。
        case available
        /// 已用，B（总量 − 可用）。
        case used
    }

    public static func storageDisk(_ key: DiskKey, _ metric: DiskMetric) -> MetricID {
        MetricID("\(diskPrefix)\(key.rawValue).\(metric.rawValue)")
    }

    public static func storageGroup(_ key: DiskKey, _ metric: GroupMetric) -> MetricID {
        MetricID("\(groupPrefix)\(key.rawValue).\(metric.rawValue)")
    }

    /// 若是每盘指标，返回盘键与指标。
    public var storageDiskMetric: (key: DiskKey, metric: DiskMetric)? {
        guard rawValue.hasPrefix(Self.diskPrefix) else { return nil }
        let rest = rawValue.dropFirst(Self.diskPrefix.count)
        guard let dot = rest.firstIndex(of: "."), let key = DiskKey(validating: rest[..<dot]),
            let metric = DiskMetric(rawValue: String(rest[rest.index(after: dot)...]))
        else { return nil }
        return (key, metric)
    }

    /// 若是容量组指标，返回组键与指标。
    public var storageGroupMetric: (key: DiskKey, metric: GroupMetric)? {
        guard rawValue.hasPrefix(Self.groupPrefix) else { return nil }
        let rest = rawValue.dropFirst(Self.groupPrefix.count)
        guard let dot = rest.firstIndex(of: "."), let key = DiskKey(validating: rest[..<dot]),
            let metric = GroupMetric(rawValue: String(rest[rest.index(after: dot)...]))
        else { return nil }
        return (key, metric)
    }
}

/// 盘的位置（IORegistry 的 Physical Interconnect Location）。
public enum DiskLocation: String, Hashable, Codable, Sendable {
    case `internal`
    case external
}

/// 介质类型。
public enum DiskMedium: String, Hashable, Codable, Sendable {
    case solidState
    case rotational
    case unknown
}

/// 一块物理盘在 RAID 里的身份。
public struct RAIDMembership: Hashable, Codable, Sendable {
    /// 所属 RAID 组的键。
    public var setKey: DiskKey
    /// 成员序号（从 0 开始，按 AppleRAID 的 member index）；读不到时为 nil。
    public var index: Int?
    /// 成员状态（`AppleRAID-MemberStatus`，例如 Online、Offline、Rebuilding），原样保留。
    public var status: String

    public init(setKey: DiskKey, index: Int?, status: String) {
        self.setKey = setKey
        self.index = index
        self.status = status
    }

    public var isOnline: Bool { status == "Online" }
}

/// 一块物理盘（结构信息，不随 tick 变化）。
public struct PhysicalDisk: Hashable, Codable, Sendable, Identifiable {
    public var key: DiskKey
    /// 型号（Product Name），去掉首尾空白。
    public var model: String
    /// 固件版本（Product Revision Level）。
    public var firmware: String?
    public var location: DiskLocation
    /// 接口名，例如 Apple Fabric、PCI-Express、USB、SATA。
    public var interconnect: String
    /// 整盘的 BSD 名，例如 disk0。
    public var bsdName: String?
    /// 整盘容量，字节。
    public var sizeBytes: UInt64?
    /// 首选块大小，字节。
    public var blockSize: UInt64?
    public var medium: DiskMedium
    /// 支持 NVMe SMART（`NVMe SMART Capable`）。
    public var smartCapable: Bool
    /// 作为 AppleRAID 成员时的身份。
    public var raid: RAIDMembership?

    public var id: DiskKey { key }

    public init(
        key: DiskKey, model: String, firmware: String?, location: DiskLocation, interconnect: String, bsdName: String?,
        sizeBytes: UInt64?, blockSize: UInt64?, medium: DiskMedium, smartCapable: Bool, raid: RAIDMembership?
    ) {
        self.key = key
        self.model = model
        self.firmware = firmware
        self.location = location
        self.interconnect = interconnect
        self.bsdName = bsdName
        self.sizeBytes = sizeBytes
        self.blockSize = blockSize
        self.medium = medium
        self.smartCapable = smartCapable
        self.raid = raid
    }
}

/// 一个 AppleRAID 组。
public struct RAIDSet: Hashable, Codable, Sendable, Identifiable {
    public var key: DiskKey
    /// 阵列名（AppleRAID-SetName，用户起的名字，不是设备标识）。
    public var name: String
    /// 级别（AppleRAID-LevelName，例如 Stripe、Mirror、Concat），原样保留。
    public var level: String
    /// 阵列状态（AppleRAID-SetStatus，例如 Online、Degraded、Offline），原样保留。
    public var status: String
    public var sizeBytes: UInt64?
    public var bsdName: String?
    /// 成员盘键，按成员序号排列。
    public var members: [DiskKey]

    public var id: DiskKey { key }

    public init(
        key: DiskKey, name: String, level: String, status: String, sizeBytes: UInt64?, bsdName: String?, members: [DiskKey]
    ) {
        self.key = key
        self.name = name
        self.level = level
        self.status = status
        self.sizeBytes = sizeBytes
        self.bsdName = bsdName
        self.members = members
    }

    public var isOnline: Bool { status == "Online" }
}

/// 物理盘清单（`DiskInventory` 的一次枚举结果）。
public struct StorageInventory: Hashable, Codable, Sendable {
    /// 物理盘：内置在前，其余按 BSD 名的数字序。
    public var disks: [PhysicalDisk]
    public var raidSets: [RAIDSet]
    /// 枚举代数：盘插拔、RAID 变化时加一。
    public var generation: UInt64

    public init(disks: [PhysicalDisk], raidSets: [RAIDSet], generation: UInt64) {
        self.disks = disks
        self.raidSets = raidSets
        self.generation = generation
    }

    public static let empty = StorageInventory(disks: [], raidSets: [], generation: 0)

    public func disk(_ key: DiskKey) -> PhysicalDisk? { disks.first { $0.key == key } }
    public func raidSet(_ key: DiskKey) -> RAIDSet? { raidSets.first { $0.key == key } }

    /// 默认绑定的盘：第一块内置盘；没有内置盘时取第一块盘。
    public var primaryDisk: PhysicalDisk? { disks.first { $0.location == .internal } ?? disks.first }
}

/// 一个卷（容量组的构成）。
public struct StorageVolume: Hashable, Codable, Sendable {
    /// 卷名（用户起的名字或系统卷名）。
    public var name: String
    /// APFS 角色（System、Data、VM、Preboot、Recovery、Update…），非 APFS 卷为 nil。
    public var role: String?
    /// 挂载点；没挂载时为 nil。
    public var mountPoint: String?
    /// 卷自己的已用量，字节（APFS 为 `ATTR_VOL_SPACEUSED`）；读不到时为 nil。
    public var usedBytes: UInt64?
    public var bsdName: String?

    public init(name: String, role: String?, mountPoint: String?, usedBytes: UInt64?, bsdName: String?) {
        self.name = name
        self.role = role
        self.mountPoint = mountPoint
        self.usedBytes = usedBytes
        self.bsdName = bsdName
    }
}

/// 容量组归属：一块物理盘，或一个 RAID 组。
public enum CapacityOwner: Hashable, Codable, Sendable {
    case disk(DiskKey)
    case raid(DiskKey)

    public var key: DiskKey {
        switch self {
        case .disk(let key), .raid(let key): key
        }
    }
}

/// 一个容量组：一个 APFS 容器，或一个非 APFS 的已挂载分区（存储模块设计 §4.4）。
public struct CapacityGroup: Hashable, Codable, Sendable, Identifiable {
    /// 组键（容器或分区的加盐哈希）。
    public var key: DiskKey
    public var owner: CapacityOwner
    /// 显示名：容器里主卷的名字（如 Macintosh HD、External），或分区卷名。
    public var name: String
    /// 文件系统（apfs、exfat、msdos、hfs…）。
    public var fileSystem: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    /// 可清除空间（访达「可用」里多出来的部分），字节；只给启动卷所在的组，且读到时才有。
    public var purgeableBytes: UInt64?
    public var volumes: [StorageVolume]
    /// 含启动卷。
    public var isBoot: Bool
    /// 辅助组：只有 Recovery、预启动等系统卷的容器（内置盘上的 Recovery 容器、iSC 预启动容器）。
    /// 不进组标题与历史，只在详情页的卷构成里列出。
    public var isAuxiliary: Bool

    public var id: DiskKey { key }
    public var usedBytes: UInt64 { totalBytes >= availableBytes ? totalBytes - availableBytes : 0 }

    public init(
        key: DiskKey, owner: CapacityOwner, name: String, fileSystem: String, totalBytes: UInt64, availableBytes: UInt64,
        purgeableBytes: UInt64?, volumes: [StorageVolume], isBoot: Bool, isAuxiliary: Bool = false
    ) {
        self.key = key
        self.owner = owner
        self.name = name
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.purgeableBytes = purgeableBytes
        self.volumes = volumes
        self.isBoot = isBoot
        self.isAuxiliary = isAuxiliary
    }
}

/// critical warning 的各位（NVMe 1.4 SMART / Health Information，字节 0）。
public struct NVMeCriticalWarning: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 可用备用块低于阈值。
    public static let spareBelowThreshold = Self(rawValue: 1 << 0)
    /// 温度超出阈值。
    public static let temperature = Self(rawValue: 1 << 1)
    /// 可靠性下降（介质或内部错误过多）。
    public static let reliabilityDegraded = Self(rawValue: 1 << 2)
    /// 介质已进入只读模式。
    public static let readOnly = Self(rawValue: 1 << 3)
    /// 易失性存储备份（电容）失效。
    public static let volatileBackupFailed = Self(rawValue: 1 << 4)
    /// 持久内存区只读或不可靠。
    public static let persistentMemoryRegion = Self(rawValue: 1 << 5)
}

/// 一次 NVMe SMART / Health 日志读数（存储模块设计 §3.2）。计数是厂商的累计值，按原样保存。
public struct SMARTRecord: Hashable, Codable, Sendable {
    public var criticalWarning: NVMeCriticalWarning
    /// 综合温度，°C。
    public var temperatureCelsius: Double
    /// 可用备用块，0…100（%）。
    public var availableSpare: Int
    /// 可用备用块阈值，0…100（%）。各厂商不同（Apple 99、Intel 10），按盘自报的值判断。
    public var availableSpareThreshold: Int
    /// 已用寿命，0…255（%）。
    public var percentageUsed: Int
    /// 耐久组 critical warning 汇总（字节 6）。
    public var enduranceGroupWarning: UInt8
    /// 数据单元：每单元 1000 个 512 字节扇区。
    public var dataUnitsRead: Double
    public var dataUnitsWritten: Double
    public var hostReadCommands: Double
    public var hostWriteCommands: Double
    /// 控制器忙碌时间，分钟。
    public var controllerBusyMinutes: Double
    public var powerCycles: Double
    public var powerOnHours: Double
    public var unsafeShutdowns: Double
    public var mediaErrors: Double
    public var errorLogEntries: Double
    /// 超过警告 / 严重温度阈值的累计时间，分钟。
    public var warningTemperatureMinutes: UInt32
    public var criticalTemperatureMinutes: UInt32
    /// 温度传感器 1–8，°C；不支持的传感器为 nil。
    public var temperatureSensors: [Double?]
    /// 热管理（TMT1 / TMT2）的切换次数与累计秒数。
    public var thermalTransitions: [UInt32]
    public var thermalSeconds: [UInt32]

    // Identify Controller 里的补充信息（读不到时为 nil）。
    /// 警告温度阈值、严重温度阈值，°C。
    public var warningThresholdCelsius: Double?
    public var criticalThresholdCelsius: Double?
    /// 控制器报告的 NVMe 版本（例如 0x10400 = 1.4），0 表示没有报告。
    public var nvmeVersion: UInt32?
    /// PCI 厂商 ID（Apple 为 0x106B）。
    public var vendorID: UInt16?

    public init(
        criticalWarning: NVMeCriticalWarning, temperatureCelsius: Double, availableSpare: Int, availableSpareThreshold: Int,
        percentageUsed: Int, enduranceGroupWarning: UInt8, dataUnitsRead: Double, dataUnitsWritten: Double,
        hostReadCommands: Double, hostWriteCommands: Double, controllerBusyMinutes: Double, powerCycles: Double,
        powerOnHours: Double, unsafeShutdowns: Double, mediaErrors: Double, errorLogEntries: Double,
        warningTemperatureMinutes: UInt32, criticalTemperatureMinutes: UInt32, temperatureSensors: [Double?],
        thermalTransitions: [UInt32], thermalSeconds: [UInt32], warningThresholdCelsius: Double? = nil,
        criticalThresholdCelsius: Double? = nil, nvmeVersion: UInt32? = nil, vendorID: UInt16? = nil
    ) {
        self.criticalWarning = criticalWarning
        self.temperatureCelsius = temperatureCelsius
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.percentageUsed = percentageUsed
        self.enduranceGroupWarning = enduranceGroupWarning
        self.dataUnitsRead = dataUnitsRead
        self.dataUnitsWritten = dataUnitsWritten
        self.hostReadCommands = hostReadCommands
        self.hostWriteCommands = hostWriteCommands
        self.controllerBusyMinutes = controllerBusyMinutes
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.errorLogEntries = errorLogEntries
        self.warningTemperatureMinutes = warningTemperatureMinutes
        self.criticalTemperatureMinutes = criticalTemperatureMinutes
        self.temperatureSensors = temperatureSensors
        self.thermalTransitions = thermalTransitions
        self.thermalSeconds = thermalSeconds
        self.warningThresholdCelsius = warningThresholdCelsius
        self.criticalThresholdCelsius = criticalThresholdCelsius
        self.nvmeVersion = nvmeVersion
        self.vendorID = vendorID
    }

    /// 一个数据单元的字节数（NVMe：1000 × 512）。
    public static let bytesPerDataUnit: Double = 512_000
    public var bytesRead: Double { dataUnitsRead * Self.bytesPerDataUnit }
    public var bytesWritten: Double { dataUnitsWritten * Self.bytesPerDataUnit }

    /// Apple 控制器（VID 0x106B）：通电时间严重低报（存储模块设计 §1），UI 标注「不可信」。
    public var isAppleController: Bool { vendorID == 0x106B }
    public var powerOnHoursUnreliable: Bool { isAppleController }
    /// Apple 控制器的忙碌时间恒为 0，按「不支持」显示。
    public var controllerBusyUnsupported: Bool { isAppleController && controllerBusyMinutes == 0 }

    /// 需要提醒的健康问题（面板概览行用来替换寿命；D54）。
    public var healthIssues: [SMARTHealthIssue] {
        var issues: [SMARTHealthIssue] = []
        if !criticalWarning.isEmpty { issues.append(.criticalWarning(criticalWarning)) }
        if availableSpare < availableSpareThreshold { issues.append(.spareBelowThreshold) }
        if mediaErrors > 0 { issues.append(.mediaErrors(mediaErrors)) }
        return issues
    }
}

/// SMART 层面的健康问题。
public enum SMARTHealthIssue: Hashable, Sendable {
    case criticalWarning(NVMeCriticalWarning)
    case spareBelowThreshold
    case mediaErrors(Double)
}

/// 驱动 Statistics 的累计计数（`IOBlockStorageDriver` 的 Statistics 字典）。
public struct DiskIOCounters: Hashable, Codable, Sendable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var reads: UInt64
    public var writes: UInt64
    /// 累计读 / 写时间，纳秒（并发 IO 会重叠计数，不能当忙碌率）。
    public var readTimeNanos: UInt64
    public var writeTimeNanos: UInt64
    public var readErrors: UInt64
    public var writeErrors: UInt64
    public var readRetries: UInt64
    public var writeRetries: UInt64

    public init(
        bytesRead: UInt64, bytesWritten: UInt64, reads: UInt64, writes: UInt64, readTimeNanos: UInt64,
        writeTimeNanos: UInt64, readErrors: UInt64 = 0, writeErrors: UInt64 = 0, readRetries: UInt64 = 0,
        writeRetries: UInt64 = 0
    ) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.reads = reads
        self.writes = writes
        self.readTimeNanos = readTimeNanos
        self.writeTimeNanos = writeTimeNanos
        self.readErrors = readErrors
        self.writeErrors = writeErrors
        self.readRetries = readRetries
        self.writeRetries = writeRetries
    }
}
