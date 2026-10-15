// swift-tools-version: 6.4
// SysKit：SysInfo 的代码分层（D23、M0 设计 §2）。
// - 私有 C 层 CSysPrivate 不做成 product，但 Xcode 和 SwiftPM 仍会把它的 module map 传给下游，
//   app 和 sysinfo-cli 在编译器层面是能 import 到它的。隔离靠两处：SysCollectors 用 `internal import`
//   不在公开接口里暴露它；scripts/check-private-imports.sh 在构建期检查 app 与 CLI 源码（见 M0 设计偏离记录）；
// - 对 app 只暴露 SysModel、SysCollectors、SysStore 三个 library product；
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
        .library(name: "SysStore", targets: ["SysStore"]),
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
            // 内置芯片档案（CPU 模块设计 §4.3）。
            resources: [.copy("Resources/ChipProfiles")],
            swiftSettings: swiftSettings
        ),

        // 历史库（CPU 模块设计 §6，D30）：系统 libsqlite3，不依赖私有层。
        .target(
            name: "SysStore",
            dependencies: ["SysModel", "SysCollectors"],
            swiftSettings: swiftSettings
        ),

        // 命令行，用于跨机对照（M0 设计 §7）。
        .executableTarget(
            name: "sysinfo-cli",
            dependencies: ["SysModel", "SysCollectors", "SysStore"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "SysModelTests",
            dependencies: ["SysModel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SysStoreTests",
            dependencies: ["SysStore", "SysCollectors", "SysModel"],
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
