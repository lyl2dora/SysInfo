// swift-tools-version: 6.4
// SysKit：SysInfo 的代码分层（D23、M0 设计 §2）。
// - 私有 C 层 CSysPrivate 不做成 product，app 在编译期 import 不到它；
// - 对 app 只暴露 SysModel、SysCollectors 两个 library product；
// - Package 内默认 nonisolated（不设 defaultIsolation），Swift 6 语言模式。
//   不开 NonisolatedNonsendingByDefault：否则 nonisolated async 函数会继承调用方（MainActor）的隔离，
//   与「采样不能在 MainActor 上运行」（D03、D23）相冲突。

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "SysKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SysModel", targets: ["SysModel"]),
        .library(name: "SysCollectors", targets: ["SysCollectors"]),
    ],
    targets: [
        // 私有 C 层。M0 只放占位头文件和 .c，不声明任何私有符号。
        .target(name: "CSysPrivate"),

        // 值类型数据模型，不依赖私有 API。
        .target(
            name: "SysModel",
            swiftSettings: swiftSettings
        ),

        // 采集层：调度器、采集器、降频信号。唯一允许依赖 CSysPrivate 的 Swift target。
        .target(
            name: "SysCollectors",
            dependencies: ["SysModel", "CSysPrivate"],
            swiftSettings: swiftSettings
        ),

        // 命令行，用于跨机对照（M0 设计 §7）。
        .executableTarget(
            name: "sysinfo-cli",
            dependencies: ["SysModel", "SysCollectors"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "SysModelTests",
            dependencies: ["SysModel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SysCollectorsTests",
            dependencies: ["SysCollectors", "SysModel"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
