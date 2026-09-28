// coalmap - runs INSIDE ITS OWN resource coalition (launched as an LSUIElement app via `open -n`), applies short controlled
// loads and prints the coalition_info_resource_usage delta for every slot next to the summed proc_pid_rusage(V6) deltas
// of all coalition members, AGX per-pid accumulatedGPUTime and IOReport AGX "GPU Energy".
// build: see build.sh
import Foundation
import Metal
import Vision
import CoreGraphics
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)
guard ck_init() != 0 else { print("ck_init failed"); exit(1) }
let cid = ck_self_cid()
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical], reason: "coalition slot mapping probe")
let scratch = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
print("coalmap pid \(getpid()) resource coalition \(cid); main-thread qos=\(qos_class_self().rawValue); scratch=\(scratch)")

func snap() -> ck_snap { var s = ck_snap(); ck_snap_take(&s, cid); return s }
func phase(_ name: String, _ body: () -> Void) {
    Thread.sleep(forTimeInterval: 2)          // gap so external top snapshots separate phases
    ck_log("BEGIN \(name)")
    var a = snap()
    body()
    var b = snap()
    ck_log("END \(name)")
    ck_print_delta(name, &a, &b)
}
func spinThread(qos: QualityOfService, seconds: Double) {
    let done = DispatchSemaphore(value: 0)
    let t = Thread {
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(seconds * 1e9)
        var x: UInt64 = 1
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { for _ in 0..<10000 { x = x &* 6364136223846793005 &+ 1442695040888963407 } }
        if x == 42 { print("impossible") }
        print("   spin thread done: qos_class_self=\(qos_class_self().rawValue)")
        done.signal()
    }
    t.qualityOfService = qos
    t.start()
    done.wait()
}

let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "all"
if mode == "gpu-modes" {
    // gpu_time vs AGX accumulatedGPUTime vs system GPUPH active residency, for compute, render and Vision-on-GPU work
    let dv = MTLCreateSystemDefaultDevice()!; let q = dv.makeCommandQueue()!
    let rsrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float4 c; };
    vertex V vs(uint vid [[vertex_id]], uint iid [[instance_id]]) {
        float2 pts[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        V o; o.p = float4(pts[vid] * (0.5 + 0.5 * float(iid % 7) / 7.0), float(iid) / 4096.0, 1); o.c = float4(float(iid % 5) / 5.0, 0.3, 0.7, 0.05); return o;
    }
    fragment float4 fs(V in [[stage_in]]) { float4 c = in.c; for (int i = 0; i < 64; i++) { c = fract(c * 1.0003 + 0.0001); } return c; }
    kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float a = float(id) * 1e-6f, b = 1.0001f;
        for (int i = 0; i < 4096; i++) { a = fma(a, b, 0.0001f); b = fma(b, 0.99999f, 1e-7f); }
        out[id] = a + b;
    }
    """
    let lb = try! dv.makeLibrary(source: rsrc, options: nil)
    let pd = MTLRenderPipelineDescriptor(); pd.vertexFunction = lb.makeFunction(name: "vs"); pd.fragmentFunction = lb.makeFunction(name: "fs")
    pd.colorAttachments[0].pixelFormat = .rgba8Unorm; pd.colorAttachments[0].isBlendingEnabled = true
    pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    let rp = try! dv.makeRenderPipelineState(descriptor: pd)
    let cp = try! dv.makeComputePipelineState(function: lb.makeFunction(name: "burn")!)
    let ob = dv.makeBuffer(length: (1 << 22) * 4, options: .storageModePrivate)!
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 3840, height: 2160, mipmapped: false); td.usage = [.renderTarget]; td.storageMode = .private
    let tex = dv.makeTexture(descriptor: td)!
    func render1() -> Double { let r = MTLRenderPassDescriptor(); r.colorAttachments[0].texture = tex; r.colorAttachments[0].loadAction = .clear; r.colorAttachments[0].storeAction = .store
        let cb = q.makeCommandBuffer()!; let e = cb.makeRenderCommandEncoder(descriptor: r)!; e.setRenderPipelineState(rp); e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 64); e.endEncoding(); cb.commit(); cb.waitUntilCompleted(); return cb.gpuEndTime - cb.gpuStartTime }
    func compute1(_ n: Int) -> Double { let cb = q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!; e.setComputePipelineState(cp); e.setBuffer(ob, offset: 0, index: 0)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: cp.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)); e.endEncoding(); cb.commit(); cb.waitUntilCompleted(); return cb.gpuEndTime - cb.gpuStartTime }
    _ = render1(); _ = compute1(1 << 22)
    phase("idle-3s") { Thread.sleep(forTimeInterval: 3) }
    phase("metal-render-4K-8s") { let st = Date(); var g = 0.0; var n = 0; while Date().timeIntervalSince(st) < 8 { g += render1(); n += 1 }; print(String(format: "   render: %d frames, MTLCommandBuffer GPU time %.3f s", n, g)) }
    phase("metal-compute-small-8s") { let st = Date(); var g = 0.0; var n = 0; while Date().timeIntervalSince(st) < 8 { g += compute1(1 << 14); n += 1 }; print(String(format: "   small compute: %d dispatches, MTLCommandBuffer GPU time %.3f s", n, g)) }
    phase("metal-compute-duty25-8s") { let st = Date(); var g = 0.0; while Date().timeIntervalSince(st) < 8 { let ps = Date(); while Date().timeIntervalSince(ps) < 0.025 { g += compute1(1 << 20) }; Thread.sleep(forTimeInterval: 0.075) }; print(String(format: "   duty25 compute: MTLCommandBuffer GPU time %.3f s", g)) }
    ck_log("coalmap gpu-modes done"); exit(0)
}
if mode == "ane-scale" {
    // ANE unit check: if ane_mach_time is in mach ticks (24 MHz), ane_mach_time/wall_ticks should approach ~1 as
    // concurrent inference threads saturate the ANE; if it were ns the ratio would stay tiny.
    let w0 = 512
    let c0 = CGContext(data: nil, width: w0, height: w0, bitsPerComponent: 8, bytesPerRow: w0 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for i in 0..<64 { c0.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)); c0.fillEllipse(in: CGRect(x: (i * 37) % w0, y: (i * 53) % w0, width: 60, height: 90)) }
    let im = c0.makeImage()!
    func inf1() { let r = VNGenerateImageFeaturePrintRequest(); if let d = try? r.supportedComputeStageDevices, let m = d[.main], let a = m.first(where: { if case .neuralEngine = $0 { return true } else { return false } }) { r.setComputeDevice(a, for: .main) }; try? VNImageRequestHandler(cgImage: im, options: [:]).perform([r]) }
    for _ in 0..<10 { inf1() }
    phase("idle-5s") { Thread.sleep(forTimeInterval: 5) }
    for nt in [1, 2, 4, 8] {
        phase("ane-\(nt)threads-6s") {
            let g = DispatchGroup(); let lock = NSLock(); var total = 0
            let st = Date()
            for _ in 0..<nt { g.enter(); let t = Thread { var n = 0; while Date().timeIntervalSince(st) < 6 { inf1(); n += 1 }; lock.lock(); total += n; lock.unlock(); g.leave() }; t.qualityOfService = .userInitiated; t.start() }
            g.wait()
            print(String(format: "   %d threads: %d inferences (%.1f/s)", nt, total, Double(total) / Date().timeIntervalSince(st)))
        }
    }
    phase("idle-5s-after") { Thread.sleep(forTimeInterval: 5) }
    ck_log("coalmap ane-scale done"); exit(0)
}
// ---------- (0) idle baseline
phase("idle-3s") { Thread.sleep(forTimeInterval: 3) }
// ---------- (a) CPU spins
phase("spin-USER_INTERACTIVE-5s") { spinThread(qos: .userInteractive, seconds: 5) }
phase("spin-BACKGROUND-5s") { spinThread(qos: .background, seconds: 5) }

// ---------- (b) Metal full-occupancy compute
let dev = MTLCreateSystemDefaultDevice()!
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float a = float(id) * 1e-6f, b = 1.0001f;
    for (int i = 0; i < 4096; i++) { a = fma(a, b, 0.0001f); b = fma(b, 0.99999f, 1e-7f); }
    out[id] = a + b;
}
"""
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let outBuf = dev.makeBuffer(length: (1 << 22) * 4, options: .storageModePrivate)!
let queue = dev.makeCommandQueue()!
func dispatchOnce() -> Double {
    let cb = queue.makeCommandBuffer()!; let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso); enc.setBuffer(outBuf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: 1 << 22, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted(); return cb.gpuEndTime - cb.gpuStartTime
}
_ = dispatchOnce()   // warm-up outside the phase
phase("metal-compute-10s") {
    let st = Date(); var g = 0.0; var n = 0
    while Date().timeIntervalSince(st) < 10 { g += dispatchOnce(); n += 1 }
    print(String(format: "   metal: %d dispatches, summed MTLCommandBuffer GPU time %.3f s over %.2f s wall", n, g, Date().timeIntervalSince(st)))
}

// ---------- (c) Vision feature print pinned to the Neural Engine
let w = 512, h = 512
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for i in 0..<64 { ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)); ctx.fillEllipse(in: CGRect(x: (i * 37) % w, y: (i * 53) % h, width: 60, height: 90)) }
let img = ctx.makeImage()!
var pinned = "default"
func infer() {
    let req = VNGenerateImageFeaturePrintRequest()
    if let devs = try? req.supportedComputeStageDevices, let main = devs[.main], let ane = main.first(where: { if case .neuralEngine = $0 { return true } else { return false } }) { req.setComputeDevice(ane, for: .main); pinned = "neuralEngine" }
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
}
for _ in 0..<10 { infer() }   // warm-up (model load / ANE compile) outside the phase
phase("ane-vision-10s") {
    let st = Date(); var n = 0
    while Date().timeIntervalSince(st) < 10 { infer(); n += 1 }
    print(String(format: "   ane: %d VNGenerateImageFeaturePrintRequest in %.2f s (%.1f/s), compute device pinned: %@", n, Date().timeIntervalSince(st), Double(n) / Date().timeIntervalSince(st), pinned))
}

// ---------- (d) 64 MiB uncached write + FULLFSYNC, then uncached read, then mmap page-ins
let path = scratch + "/coalmap_io.bin"
let size = 64 << 20
let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
arc4random_buf(buf, size)
phase("disk-write-64MiB-nocache-fullfsync") {
    let fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0o644); _ = fcntl(fd, F_NOCACHE, 1)
    let wr = write(fd, buf, size); let fs = fcntl(fd, F_FULLFSYNC); close(fd)
    print("   wrote \(wr) bytes, F_FULLFSYNC rc=\(fs)")
}
phase("disk-read-64MiB-nocache") {
    let fd = open(path, O_RDONLY); _ = fcntl(fd, F_NOCACHE, 1); let rd = read(fd, buf, size); close(fd)
    print("   read \(rd) bytes")
}
phase("mmap-pagein-64MiB") {
    let fd = open(path, O_RDONLY); let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)!; var acc: UInt64 = 0
    var off = 0; while off < size { acc &+= UInt64(p.load(fromByteOffset: off, as: UInt8.self)); off += 16384 }
    munmap(p, size); close(fd); print("   touched \(size / 16384) file pages, acc=\(acc)")
}
unlink(path)
phase("anon-touch-256MiB") {
    let n = 256 << 20; let p = mmap(nil, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)!
    var off = 0; while off < n { p.storeBytes(of: 1, toByteOffset: off, as: UInt8.self); off += 16384 }
    munmap(p, n); print("   zero-fill touched \(n / 16384) anon pages")
}
// ---------- (e) wakeups
phase("idle-5s") { Thread.sleep(forTimeInterval: 5) }
phase("timer-1kHz-5s") {
    let done = DispatchSemaphore(value: 0)
    let t = Thread { let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 5_000_000_000; var k = 0; while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { usleep(1000); k += 1 }; print("   \(k) usleep(1000) wakeups"); done.signal() }
    t.qualityOfService = .default; t.start(); done.wait()
}
ProcessInfo.processInfo.endActivity(activity)
ck_log("coalmap done")
