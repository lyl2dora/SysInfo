import AppKit
import SwiftUI
import WidgetKit
import AppIntents
import Metal
import Charts

final class Del: NSObject, NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {}
    @objc func clicked() {}
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {}
}
// compile-only use of un-deprecated NSStatusItem.view/target/action (no status item is created at runtime)
func configure(_ item: NSStatusItem, d: Del) {
    item.view = NSView()
    item.target = d
    item.action = #selector(Del.clicked)
    item.expandedInterfaceDelegate = d
    _ = item.expandedInterfaceSession?.cancel()
}
struct Probe: AppIntent {
    static let title: LocalizedStringResource = "Probe"
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult { .result() }
}
struct EnvProbe: View {
    @Environment(\.systemPrefersReducedResourceUsage) var reduced
    var body: some View { Text(reduced ? "reduced" : "normal") }
}
struct ChartProbe: View {
    let flag: Bool
    var body: some View {
        Chart {
            if flag { BarMark(x: .value("x", 1), y: .value("y", 2)) } else { LineMark(x: .value("x", 1), y: .value("y", 2)) }
        }
    }
}
let mi = NSMenuItem(title: "t", action: nil, keyEquivalent: "")
print("NSMenuItem.preferredImageVisibility default rawValue =", mi.preferredImageVisibility.rawValue)
mi.preferredImageVisibility = .visible
print("after set .visible rawValue =", mi.preferredImageVisibility.rawValue)
let g = NSGlassEffectView()
print("NSGlassEffectView.effectIsInteractive default =", g.effectIsInteractive)
g.effectIsInteractive = true
print("after set =", g.effectIsInteractive)
print("NSStatusItem responds setExpandedInterfaceDelegate:", NSStatusItem.instancesRespond(to: Selector(("setExpandedInterfaceDelegate:"))))
print("NSStatusItem responds expandedInterfaceSession:", NSStatusItem.instancesRespond(to: Selector(("expandedInterfaceSession"))))
print("NSStatusItemExpandedInterfaceSession class:", NSClassFromString("NSStatusItemExpandedInterfaceSession") as Any)
print("NSViewCornerConfiguration class:", NSClassFromString("NSViewCornerConfiguration") as Any)
print("IntentExecutionTargets main/appex/widget:", IntentExecutionTargets.main.rawValue, IntentExecutionTargets.appIntentsExtension.rawValue, IntentExecutionTargets.widgetKitExtension.rawValue, "default:", IntentExecutionTargets.default.rawValue)
print("WidgetFamily.systemExtraLargePortrait:", WidgetFamily.systemExtraLargePortrait)
var env = EnvironmentValues()
print("EnvironmentValues().systemPrefersReducedResourceUsage =", env.systemPrefersReducedResourceUsage)
if let dev = MTLCreateSystemDefaultDevice() { print("MTL device:", dev.name, "isLowPower(deprecated)=", dev.isLowPower, "registryID=", dev.registryID) }
print("ProcessInfo.thermalState raw=", ProcessInfo.processInfo.thermalState.rawValue, "lowPower=", ProcessInfo.processInfo.isLowPowerModeEnabled)
