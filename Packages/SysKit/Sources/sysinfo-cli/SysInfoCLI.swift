// sysinfo-cli：跨机对照用的命令行（M0 设计 §7）。
//
// 脚手架阶段只实现 `version` 和帮助；`selftest`、`cpu` 在采集器落地后接上。

import Foundation
import SysCollectors
import SysModel

@main
struct SysInfoCLI {
    static func main() {
        var arguments = CommandLine.arguments.dropFirst()
        let command = arguments.popFirst() ?? "help"

        switch command {
        case "help", "-h", "--help":
            printUsage()
        case "version", "--version":
            print("sysinfo-cli（SysKit）私有层版本 \(PrivateLayer.version)")
        case "selftest", "cpu":
            printError("子命令 \(command) 尚未实现：采集器在 M0 后续阶段接入。")
            exit(2)
        default:
            printError("未知子命令：\(command)")
            printUsage()
            exit(64)  // EX_USAGE
        }
    }

    static func printUsage() {
        print(
            """
            用法：sysinfo-cli <子命令> [选项]

            子命令：
              selftest                               运行所有采集器的自检并打印结果（待实现）
              cpu [--interval 1] [--count 5] [--json] 逐次打印总占用和每核占用（待实现）
              version                                打印版本信息
              help                                   打印本帮助
            """
        )
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
