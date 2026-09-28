// Probe helper: drive the Neural Engine from our own process via Vision (compute device pinned to ANE when available)
// usage: aneload <seconds>
// build: xcrun swiftc -O -o aneload aneload.swift -framework Vision -framework CoreML -framework CoreGraphics
import Foundation
import Vision
import CoreML
import CoreGraphics

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 10

// synthetic 512x512 image
let w = 512, h = 512
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for i in 0..<64 {
    ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: (i * 37) % w, y: (i * 53) % h, width: 60, height: 90))
}
let img = ctx.makeImage()!

print("MLModel.availableComputeDevices: \(MLModel.availableComputeDevices.map { "\($0)" })")
let start = Date()
var n = 0
var pinned = "default"
while Date().timeIntervalSince(start) < seconds {
    let req = VNGenerateImageFeaturePrintRequest()
    if let devs = try? req.supportedComputeStageDevices, let main = devs[.main] {
        if let ane = main.first(where: { if case .neuralEngine = $0 { return true } else { return false } }) {
            req.setComputeDevice(ane, for: .main); pinned = "neuralEngine"
        }
    }
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    do { try handler.perform([req]) } catch { print("perform error: \(error)"); break }
    n += 1
}
print(String(format: "aneload: %d VNGenerateImageFeaturePrintRequest in %.2fs (%.1f/s), compute device pinned: %@, pid %d", n, Date().timeIntervalSince(start), Double(n) / Date().timeIntervalSince(start), pinned, getpid()))
