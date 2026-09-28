import AppKit
import SwiftUI
struct Probe: View {
  @Environment(\.systemPrefersReducedResourceUsage) var reduced
  @Environment(\.accessibilityReduceTransparency) var rt
  var body: some View {
    Color.clear.frame(width: 10, height: 10).onAppear { print("systemPrefersReducedResourceUsage =", reduced, " accessibilityReduceTransparency =", rt) }
  }
}
@MainActor func run() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
  w.contentView = NSHostingView(rootView: Probe())
  w.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(0.5))
  print("ProcessInfo.isLowPowerModeEnabled =", ProcessInfo.processInfo.isLowPowerModeEnabled, " thermalState =", ProcessInfo.processInfo.thermalState.rawValue)
  print("UserDefaults NSGlassTintAmount =", UserDefaults.standard.object(forKey: "NSGlassTintAmount") ?? "nil")
  w.orderOut(nil)
}
MainActor.assumeIsolated { run() }
