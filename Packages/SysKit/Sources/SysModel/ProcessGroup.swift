// Top N 的值类型（CPU 模块设计 §5.7，边界稿 §5.3，D31）。

/// 能不能在 UI 上提供「结束」按钮（D31）。
public enum TerminationEligibility: String, Hashable, Codable, Sendable {
    /// 同 uid 的进程：可以结束（先确认，按住 ⌥ 默认强制）。
    case allowed
    /// SysInfo 自身。
    case isSelf
    /// root 进程：不提权结束（D04）。
    case root
    /// 其他用户的进程。
    case otherUser
    /// 多成员的组行：不提供按钮（展开后对成员逐个判断）。
    case group
    /// 读不到 uid（进程刚退出等）。
    case unknown

    public var isAllowed: Bool { self == .allowed }
}

/// 展开后的一个成员。
public struct TopNMember: Hashable, Codable, Sendable {
    public var pid: Int32
    public var name: String
    /// 可执行文件路径（app 用来取图标）；读不到时为 nil。
    public var path: String?
    /// 窗口内的 CPU，按单核比例；第一次出现、还没有差分时为 nil。
    public var cpu: Double?
    public var eligibility: TerminationEligibility

    public init(pid: Int32, name: String, path: String?, cpu: Double?, eligibility: TerminationEligibility) {
        self.pid = pid
        self.name = name
        self.path = path
        self.cpu = cpu
        self.eligibility = eligibility
    }
}

/// Top N 的一行：按应用视图里是一个 coalition，按进程视图里是一个进程或一个分不开的组。
public struct TopNRow: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case coalition, process, group
    }

    /// 行的稳定标识：coalition 为 `c<id>`，进程为 `p<pid>`。
    public var id: String
    public var kind: Kind
    public var coalitionID: UInt64
    /// 行名：代表成员所在 .app 的名字，或可执行文件名；pid 0 为 kernel_task。
    public var name: String
    /// 代表成员所在 .app 的路径（取图标用）。
    public var appPath: String?
    public var representativePID: Int32
    public var memberCount: Int
    /// 窗口内的 CPU，按单核比例（1 = 占满一个核）。
    public var cpu: Double
    /// 在 perflevel0 上的时间占比（只在两档芯片、拓扑与槽位核对都通过时给出）。
    public var perfLevel0Share: Double?
    /// 窗口内的平均功率，W（coalition 能耗槽）；槽位不可信时为 nil。
    public var energyWatts: Double?
    /// 宿主 coalition 的副标题：占用最高的成员（不是代表成员时才给），例如终端里的 claude。
    public var topMember: TopNMember?
    /// 展开后的同 uid 成员（按 CPU 降序）。
    public var members: [TopNMember]
    /// 外部成员（root 与其他用户）合计的 CPU：只在窗口内成员没有变化时才算，否则为 nil。
    public var residualCPU: Double?
    public var residualCount: Int
    public var eligibility: TerminationEligibility

    public init(
        id: String, kind: Kind, coalitionID: UInt64, name: String, appPath: String?, representativePID: Int32,
        memberCount: Int, cpu: Double, perfLevel0Share: Double?, energyWatts: Double?, topMember: TopNMember?,
        members: [TopNMember], residualCPU: Double?, residualCount: Int, eligibility: TerminationEligibility
    ) {
        self.id = id
        self.kind = kind
        self.coalitionID = coalitionID
        self.name = name
        self.appPath = appPath
        self.representativePID = representativePID
        self.memberCount = memberCount
        self.cpu = cpu
        self.perfLevel0Share = perfLevel0Share
        self.energyWatts = energyWatts
        self.topMember = topMember
        self.members = members
        self.residualCPU = residualCPU
        self.residualCount = residualCount
        self.eligibility = eligibility
    }
}

/// Top N 的分组方式（D31）。
public enum TopNGrouping: String, Hashable, Codable, Sendable, CaseIterable {
    case byApp
    case byProcess
}
