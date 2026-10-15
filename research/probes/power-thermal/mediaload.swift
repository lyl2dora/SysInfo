// Probe helper: drive the media engines from our own process via VideoToolbox (hardware required)
// usage: mediaload <hevc|h264|prores|decode> <seconds>
// build: xcrun swiftc -O -o mediaload mediaload.swift -framework VideoToolbox -framework CoreMedia -framework CoreVideo
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hevc"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 10
let fpsCap = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 0
let W: Int32 = 3840, H: Int32 = 2160

func makePool() -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
                                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    return pool!
}
func frame(_ pool: CVPixelBufferPool, _ i: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    for p in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(pb!, p)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb!, p), rows = CVPixelBufferGetHeightOfPlane(pb!, p)
        // moving gradient so each frame differs
        for y in stride(from: 0, to: rows, by: 1) { memset(base + y * bpr, Int32((y + i * 7) & 0xff), bpr) }
    }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

var encoded: [CMSampleBuffer] = []
let lock = NSLock()
func encode(codec: CMVideoCodecType, seconds: Double, keep: Bool) -> (Int, String) {
    var session: VTCompressionSession?
    let spec: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
    let st = VTCompressionSessionCreate(allocator: nil, width: W, height: H, codecType: codec, encoderSpecification: spec as CFDictionary,
                                        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let s = session else { return (0, "VTCompressionSessionCreate failed \(st)") }
    var hw: CFBoolean?
    VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
    let pool = makePool()
    let start = Date(); var n = 0
    while Date().timeIntervalSince(start) < seconds {
        if fpsCap > 0 { let due = start.addingTimeInterval(Double(n) / fpsCap); let w = due.timeIntervalSinceNow; if w > 0 { Thread.sleep(forTimeInterval: w) } }
        let pb = frame(pool, n)
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: CMTime(value: CMTimeValue(n), timescale: 60), duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            if keep, status == noErr, let sb = sb { lock.lock(); if encoded.count < 240 { encoded.append(sb) }; lock.unlock() }
        }
        n += 1
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(s)
    return (n, "hardware=\(hw.map { CFBooleanGetValue($0) } ?? false)")
}

func decode(seconds: Double) -> (Int, String) {
    _ = encode(codec: kCMVideoCodecType_HEVC, seconds: 3, keep: true)
    guard let first = encoded.first, let fmt = CMSampleBufferGetFormatDescription(first) else { return (0, "no encoded frames") }
    var session: VTDecompressionSession?
    let spec: [String: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
    let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    guard st == noErr, let s = session else { return (0, "VTDecompressionSessionCreate failed \(st)") }
    var hw: CFBoolean?
    VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
    print("decode phase starts (encoded \(encoded.count) frames first)"); fflush(stdout)
    let start = Date(); var n = 0
    while Date().timeIntervalSince(start) < seconds {
        for sb in encoded {
            VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { _, _, _, _, _ in }
            n += 1
        }
        VTDecompressionSessionWaitForAsynchronousFrames(s)
    }
    VTDecompressionSessionInvalidate(s)
    return (n, "hardware=\(hw.map { CFBooleanGetValue($0) } ?? false)")
}

let t0 = Date()
let r: (Int, String)
switch mode {
case "h264": r = encode(codec: kCMVideoCodecType_H264, seconds: seconds, keep: false)
case "prores": r = encode(codec: kCMVideoCodecType_AppleProRes422, seconds: seconds, keep: false)
case "decode": r = decode(seconds: seconds)
default: r = encode(codec: kCMVideoCodecType_HEVC, seconds: seconds, keep: false)
}
print(String(format: "mediaload %@: %d frames 3840x2160 in %.2fs (%.1f fps) %@ pid %d", mode, r.0, Date().timeIntervalSince(t0), Double(r.0) / Date().timeIntervalSince(t0), r.1, getpid()))
