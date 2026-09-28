// 硬件测试的标签与开关（K25，M0 设计 §8）。
//
// 硬件测试依赖真实机器的读数，默认跳过；设置环境变量 SYSINFO_HW_TESTS=1 才运行（`make test-hw`）。
// 用环境变量而不是命令行过滤，是为了让直接执行 `swift test` 时同样默认跳过。

import Foundation
import Testing

extension Tag {
    @Tag static var hardware: Self
}

extension Trait where Self == ConditionTrait {
    /// 与 `.tags(.hardware)` 一起使用：未设置 SYSINFO_HW_TESTS=1 时跳过。
    static var hardwareOnly: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["SYSINFO_HW_TESTS"] == "1",
            "硬件测试默认跳过；用 make test-hw（SYSINFO_HW_TESTS=1）运行"
        )
    }
}
