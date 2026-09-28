// Lists what ExtensionFoundation discovery returns for the widgetkit extension point (the same discovery chronod uses).
import Foundation
import ExtensionFoundation
let point = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.apple.widgetkit-extension"
let sema = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let seq = try AppExtensionIdentity.matching(appExtensionPointIDs: point)
        var n = 0
        for try await ids in seq {
            let list = ids.map { $0.bundleIdentifier }.sorted()
            print("emission \(n): \(list.count) identities for \(point)")
            for b in list { print("  \(b)") }
            n += 1
            if n >= 1 { break }
        }
    } catch { print("error: \(error)") }
    sema.signal()
}
if sema.wait(timeout: .now() + 10) == .timedOut { print("timeout waiting for discovery") }
