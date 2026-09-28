// Review probe: does H11ANEIn CurrentPowerState reflect ANE *activity* or merely an open ANE client/session?
// Runs Vision feature-print on the ANE for 3 s, then stays alive idle (holding request + sequence handler) for 8 s, then runs 3 s again.
// Samples CurrentPowerState every 0.5 s from a background thread.
// build: xcrun swiftc -O -o ane_hold ane_hold.swift -framework Vision -framework CoreGraphics -framework IOKit
import Foundation
import Vision
import IOKit
func ps() -> Int {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn")); defer { IOObjectRelease(s) }
    let pm = IORegistryEntryCreateCFProperty(s, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    return (pm?["CurrentPowerState"] as? Int) ?? -1
}
let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 50, y: 60, width: 300, height: 200))
let img = ctx.makeImage()!
let req = VNGenerateImageFeaturePrintRequest()
if let devs = try? req.supportedComputeStageDevices, let main = devs[.main], let ane = main.first(where: { if case .neuralEngine = $0 { return true } else { return false } }) { req.setComputeDevice(ane, for: .main) }
let seq = VNSequenceRequestHandler()
var phase = "start"
let t0 = Date()
Thread.detachNewThread { while true { print(String(format: "t=%5.1f phase=%-6@ ANE_PS=%d", Date().timeIntervalSince(t0), phase, ps())); fflush(stdout); Thread.sleep(forTimeInterval: 0.5) } }
func run(_ s: Double) { phase = "BUSY"; let st = Date(); var n = 0; while Date().timeIntervalSince(st) < s { try? seq.perform([req], on: img); n += 1 }; print("ran \(n) inferences"); phase = "idle" }
Thread.sleep(forTimeInterval: 1)
run(3); Thread.sleep(forTimeInterval: 8); run(3); Thread.sleep(forTimeInterval: 3)
print("exit")
