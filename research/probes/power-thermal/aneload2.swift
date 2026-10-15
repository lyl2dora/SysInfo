// aneload2.swift - drive the Neural Engine at maximum rate from our own process: N concurrent threads each running
// VNGenerateImageFeaturePrintRequest pinned to the ANE compute device.  usage: aneload2 <seconds> <threads>
// build: xcrun swiftc -O -o aneload2 aneload2.swift -framework Vision -framework CoreML -framework CoreGraphics
import Foundation
import Vision
import CoreML
import CoreGraphics
let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 10
let nth = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 4
let w = 512, h = 512
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for i in 0..<64 { ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)); ctx.fillEllipse(in: CGRect(x: (i * 37) % w, y: (i * 53) % h, width: 60, height: 90)) }
let img = ctx.makeImage()!
let start = Date()
let lock = NSLock(); var total = 0; var pinnedAll = true
DispatchQueue.concurrentPerform(iterations: nth) { _ in
    var n = 0
    let req = VNGenerateImageFeaturePrintRequest()
    var pinned = false
    if let devs = try? req.supportedComputeStageDevices, let main = devs[.main],
       let ane = main.first(where: { if case .neuralEngine = $0 { return true } else { return false } }) { req.setComputeDevice(ane, for: .main); pinned = true }
    while Date().timeIntervalSince(start) < seconds {
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do { try handler.perform([req]) } catch { print("perform error: \(error)"); break }
        n += 1
    }
    lock.lock(); total += n; if !pinned { pinnedAll = false }; lock.unlock()
}
let el = Date().timeIntervalSince(start)
print(String(format: "aneload2: %d threads, %d requests in %.2fs (%.1f/s), all pinned to ANE: %@", nth, total, el, Double(total)/el, pinnedAll ? "yes" : "no"))
