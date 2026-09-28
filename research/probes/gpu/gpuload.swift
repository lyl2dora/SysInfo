// Probe: MTLDevice info + GPU load generator (own process only)
// usage: gpuload info | gpuload load <seconds> [allocMB]
// build: xcrun swiftc -O -o gpuload gpuload.swift -framework Metal
import Foundation
import Metal

guard let dev = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(1) }
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "info"

func info() {
    print("name: \(dev.name)")
    print("architecture.name: \(dev.architecture.name)")
    print("registryID: 0x\(String(dev.registryID, radix: 16))")
    print("hasUnifiedMemory: \(dev.hasUnifiedMemory)  isLowPower: \(dev.isLowPower)  isHeadless: \(dev.isHeadless)  isRemovable: \(dev.isRemovable)")
    print("location: \(dev.location.rawValue)  locationNumber: \(dev.locationNumber)  peerGroupID: \(dev.peerGroupID)")
    print(String(format: "recommendedMaxWorkingSetSize: %.2f GB", Double(dev.recommendedMaxWorkingSetSize) / 1_073_741_824))
    print(String(format: "maxBufferLength: %.2f GB", Double(dev.maxBufferLength) / 1_073_741_824))
    print(String(format: "currentAllocatedSize (this process): %.2f MB", Double(dev.currentAllocatedSize) / 1_048_576))
    print("maxThreadsPerThreadgroup: \(dev.maxThreadsPerThreadgroup.width)  maxThreadgroupMemoryLength: \(dev.maxThreadgroupMemoryLength)")
    print("supportsRaytracing: \(dev.supportsRaytracing)  supportsDynamicLibraries: \(dev.supportsDynamicLibraries)")
    var fams: [String] = []
    for (n, f) in [("apple7", MTLGPUFamily.apple7), ("apple8", .apple8), ("apple9", .apple9), ("apple10", .apple10), ("apple11", MTLGPUFamily(rawValue: 1011)!), ("metal3", .metal3), ("metal4", .metal4)] {
        if dev.supportsFamily(f) { fams.append(n) }
    }
    print("supportsFamily: \(fams.joined(separator: ","))")
    print("all devices (MTLCopyAllDevices): \(MTLCopyAllDevices().map { $0.name })")
    // IORegistry cross-check via registryID
    let matching = IORegistryEntryIDMatching(dev.registryID)
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    if svc != 0 {
        let cores = IORegistryEntryCreateCFProperty(svc, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        var cls = [CChar](repeating: 0, count: 128); IOObjectGetClass(svc, &cls)
        print("IORegistry entry for registryID: class=\(String(cString: cls)) gpu-core-count=\(cores.map { "\($0)" } ?? "nil")")
        IOObjectRelease(svc)
    }
}

func load(seconds: Double, allocMB: Int) {
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
    let n = 1 << 22
    let out = dev.makeBuffer(length: n * 4, options: .storageModePrivate)!
    var hold: [MTLBuffer] = []
    if allocMB > 0 {
        // allocate and touch (blit fill) buffers so the GPU driver accounts them
        let q0 = dev.makeCommandQueue()!
        for _ in 0..<(allocMB / 256) {
            let b = dev.makeBuffer(length: 256 << 20, options: .storageModePrivate)!
            let cb = q0.makeCommandBuffer()!; let bl = cb.makeBlitCommandEncoder()!
            bl.fill(buffer: b, range: 0..<b.length, value: 1); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            hold.append(b)
        }
        print(String(format: "allocated %d MB; currentAllocatedSize=%.1f MB", allocMB, Double(dev.currentAllocatedSize) / 1_048_576))
    }
    let q = dev.makeCommandQueue()!
    let start = Date()
    var iters = 0
    var gpuTime = 0.0
    while Date().timeIntervalSince(start) < seconds {
        let cb = q.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso); enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        gpuTime += cb.gpuEndTime - cb.gpuStartTime
        iters += 1
    }
    let wall = Date().timeIntervalSince(start)
    print(String(format: "load done: %d dispatches, wall %.2fs, summed GPU time %.2fs (%.0f%% busy from this process), pid %d", iters, wall, gpuTime, 100 * gpuTime / wall, getpid()))
    _ = hold.count
}

// duty-cycled compute: busy for duty*period, idle for the rest
func duty(seconds: Double, duty: Double) {
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float a = float(id) * 1e-6f, b = 1.0001f;
        for (int i = 0; i < 512; i++) { a = fma(a, b, 0.0001f); b = fma(b, 0.99999f, 1e-7f); }
        out[id] = a + b;
    }
    """
    let lib = try! dev.makeLibrary(source: src, options: nil)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
    let n = 1 << 22
    let out = dev.makeBuffer(length: n * 4, options: .storageModePrivate)!
    let q = dev.makeCommandQueue()!
    let period = 0.1
    let start = Date(); var gpuTime = 0.0
    while Date().timeIntervalSince(start) < seconds {
        let ps = Date()
        while Date().timeIntervalSince(ps) < duty * period {
            let cb = q.makeCommandBuffer()!; let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso); enc.setBuffer(out, offset: 0, index: 0)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted(); gpuTime += cb.gpuEndTime - cb.gpuStartTime
        }
        let rest = period - Date().timeIntervalSince(ps)
        if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    }
    let wall = Date().timeIntervalSince(start)
    print(String(format: "duty %.0f%% done: wall %.2fs, GPU time %.2fs (%.0f%% measured busy), pid %d", duty * 100, wall, gpuTime, 100 * gpuTime / wall, getpid()))
}

// offscreen render load: many large overlapping triangles into a 4K texture (exercises renderer + tiler)
func render(seconds: Double) {
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float4 c; };
    vertex V vs(uint vid [[vertex_id]], uint iid [[instance_id]]) {
        float2 pts[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        V o; o.p = float4(pts[vid] * (0.5 + 0.5 * float(iid % 7) / 7.0), float(iid) / 4096.0, 1); o.c = float4(float(iid % 5) / 5.0, 0.3, 0.7, 0.05); return o;
    }
    fragment float4 fs(V in [[stage_in]]) { float4 c = in.c; for (int i = 0; i < 64; i++) { c = fract(c * 1.0003 + 0.0001); } return c; }
    """
    let lib = try! dev.makeLibrary(source: src, options: nil)
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "vs"); pd.fragmentFunction = lib.makeFunction(name: "fs")
    pd.colorAttachments[0].pixelFormat = .rgba8Unorm
    pd.colorAttachments[0].isBlendingEnabled = true
    pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    let pso = try! dev.makeRenderPipelineState(descriptor: pd)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 3840, height: 2160, mipmapped: false)
    td.usage = [.renderTarget]; td.storageMode = .private
    let tex = dev.makeTexture(descriptor: td)!
    let q = dev.makeCommandQueue()!
    let start = Date(); var gpuTime = 0.0; var frames = 0
    while Date().timeIntervalSince(start) < seconds {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        let cb = q.makeCommandBuffer()!; let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pso)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 64)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted(); gpuTime += cb.gpuEndTime - cb.gpuStartTime; frames += 1
    }
    let wall = Date().timeIntervalSince(start)
    print(String(format: "render done: %d frames, wall %.2fs, GPU time %.2fs (%.0f%% busy), pid %d", frames, wall, gpuTime, 100 * gpuTime / wall, getpid()))
}

if mode == "info" { info() }
else if mode == "duty" { duty(seconds: Double(args[2])!, duty: Double(args[3])!) }
else if mode == "render" { render(seconds: Double(args[2])!) }
else { load(seconds: args.count > 2 ? Double(args[2])! : 10, allocMB: args.count > 3 ? Int(args[3])! : 0) }
