// 私有 C 层的元信息（D05、D23、D26）。
//
// CSysPrivate 只能在 SysCollectors 内部 import，并且用 `internal import`，这样它不会出现在 SysCollectors 的公开接口里。
// 注意：这并不能让上层（app、CLI）拿不到它的符号——它们直接 `import CSysPrivate` 也能编译通过
// （module map 会传给下游）。拦截靠 scripts/check-private-imports.sh 的构建期检查（D26）。
internal import CSysPrivate

/// 私有 C 层的元信息，供诊断页和 sysinfo-cli 显示。
public enum PrivateLayer: Sendable {
    /// 链接到的私有 C 层接口版本号。M0 为 0（只有占位）；CPU 模块从 1 开始；应用活动（D69）为 2。
    public static var version: UInt32 {
        csp_layer_version()
    }

    /// 各组私有接口在本机运行时是否解析得到（只看符号，不代表数据源自检通过）。
    public struct Availability: Hashable, Sendable {
        public var ioReport: Bool
        public var coalition: Bool
        /// 能否打开 AppleSMC 用户客户端（只读）。
        public var smc: Bool
        /// 电源断言变化通知的登记函数（IOPMAssertionNotify，D69）。
        public var assertionNotify: Bool
    }

    public static func availability() -> Availability {
        Availability(
            ioReport: IOReportHub.shared.isAvailable,
            coalition: CoalitionReader.isAvailable,
            smc: (try? SMCReader().open()) != nil, assertionNotify: csp_pm_available() != 0)
    }
}
