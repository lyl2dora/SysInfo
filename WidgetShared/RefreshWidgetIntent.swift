// 小组件上的刷新按钮（D90 W3，规格 §5）。两个 target 都编进去：扩展用它构造按钮，
// `allowedExecutionTargets = .main` 让系统把 perform 放到正在运行的主 app 里执行（probe C：不拉到前台、不计预算）。

import AppIntents
import WidgetKit

struct RefreshWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新 SysInfo 小组件"
    static let isDiscoverable = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    /// 主 app 启动时设置：现采一次、写快照、刷新组件。扩展里为 nil。
    nonisolated(unsafe) static var handler: (@MainActor () async -> Void)?

    func perform() async throws -> some IntentResult {
        if let handler = Self.handler {
            await handler()
        } else {
            // 不应走到这里（只允许在主进程执行）；兜底只刷新一次组件。
            WidgetCenter.shared.reloadTimelines(ofKind: "overview")
        }
        return .result()
    }
}
