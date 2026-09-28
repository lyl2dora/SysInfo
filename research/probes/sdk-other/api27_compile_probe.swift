// Compile-and-run probe: confirms selected macOS 27 SDK symbols resolve with
// -target arm64-apple-macos27.0, prints runtime values that don't need an app
// bundle, and surfaces deprecation warnings for Metal APIs deprecated in 27.
import Foundation
import Metal
import MetricKit
import StateReporting
import WidgetKit
import AppIntents
import Network

let pi = ProcessInfo.processInfo
print("thermalState(raw)=\(pi.thermalState.rawValue) lowPowerMode=\(pi.isLowPowerModeEnabled) activeCPUs=\(pi.activeProcessorCount) phys=\(pi.physicalMemory / (1 << 30))GiB os=\(pi.operatingSystemVersionString)")

// MetricKit 27: Swift MetricManager (own-process reports only; delivered <= daily)
let mm = MetricManager()
print("MetricManager created: \(type(of: mm)); enabledDomains=\(mm.enabledStateReportingDomains)")
print("MetricGroup.gpu=\(MetricGroup.gpu.rawValue) cpu=\(MetricGroup.cpu.rawValue)")

// StateReporting 27
let rep = StateReporter.reporter(for: "com.example.sysmon.popover")
rep.reportTransition(to: "idle")
print("StateReporter domain=\(rep.domain)")

// WidgetKit 27: new family on macOS
print("WidgetFamily.systemExtraLargePortrait raw=\(WidgetFamily.systemExtraLargePortrait.rawValue)")

// AppIntents 27: execution targets
let t: IntentExecutionTargets = [.main, .widgetKitExtension]
print("IntentExecutionTargets rawValue=\(t.rawValue) main=\(IntentExecutionTargets.main.rawValue) appex=\(IntentExecutionTargets.appIntentsExtension.rawValue) widget=\(IntentExecutionTargets.widgetKitExtension.rawValue)")

// Metal: GPU info available from public API + 27 deprecations (expect warnings)
if let d = MTLCreateSystemDefaultDevice() {
    print("MTLDevice name=\(d.name) unified=\(d.hasUnifiedMemory) recMaxWS=\(d.recommendedMaxWorkingSetSize / (1 << 20))MiB allocated(own)=\(d.currentAllocatedSize) registryID=\(d.registryID)")
    print("deprecated-in-27: lowPower=\(d.isLowPower) headless=\(d.isHeadless) removable=\(d.isRemovable) location=\(d.location.rawValue) maxTransferRate=\(d.maxTransferRate)")
    print("MTLCopyAllDevices count=\(MTLCopyAllDevices().count)")
}

// Network 27: TCP pacing API presence (compile-time check only)
let _ = NWProtocolTCP.Options.self
print("done")
