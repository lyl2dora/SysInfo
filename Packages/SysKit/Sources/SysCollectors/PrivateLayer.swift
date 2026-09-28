// 私有 C 层的唯一入口（D05、D23）。
//
// CSysPrivate 只能在 SysCollectors 内部 import，并且用 `internal import`，
// 这样它不会出现在 SysCollectors 的公开接口里，上层（app、CLI）也拿不到它的符号。
internal import CSysPrivate

/// 私有 C 层的元信息，供诊断页和 sysinfo-cli 显示。
public enum PrivateLayer: Sendable {
    /// 链接到的私有 C 层接口版本号；M0 为 0，表示只有占位、没有任何私有符号。
    public static var version: UInt32 {
        csp_layer_version()
    }
}
