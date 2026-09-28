// Review load generator (own process only). ALU-bound kernel, several submission patterns.
// usage: rload pipe <sec> <iters>          -- 3 command buffers in flight, no CPU gaps
//        rload serial <sec> <iters>        -- commit + waitUntilCompleted back-to-back (original agent's pattern)
//        rload duty <sec> <duty> <iters>   -- busy duty*100ms, idle rest
// prints dispatches, mean GPU ms per dispatch, busy %
// build: xcrun swiftc -O -o rload rload.swift -framework Metal
import Foundation
import Metal
let dev = MTLCreateSystemDefaultDevice()!
let a = CommandLine.arguments
let mode = a[1], secs = Double(a[2])!
let iters = Int(a.last!)!
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void alu(device float *out [[buffer(0)]], constant int &n [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    float x0 = float(id & 1023) * 1e-7f, x1 = x0 + 0.1f, x2 = x0 + 0.2f, x3 = x0 + 0.3f;
    for (int i = 0; i < n; i++) { x0 = fma(x0, 0.999999f, 1e-7f); x1 = fma(x1, 0.999999f, 1e-7f); x2 = fma(x2, 0.999999f, 1e-7f); x3 = fma(x3, 0.999999f, 1e-7f); }
    out[id & 65535] = x0 + x1 + x2 + x3;
}
"""
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "alu")!)
let out = dev.makeBuffer(length: 65536 * 4, options: .storageModePrivate)!
let q = dev.makeCommandQueue()!
let n = Int(ProcessInfo.processInfo.environment["THREADS"] ?? "") ?? (1 << 20)  // THREADS env overrides grid size
var itersVar = Int32(iters)
func make() -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(pso); e.setBuffer(out, offset: 0, index: 0); e.setBytes(&itersVar, length: 4, index: 1)
    e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding(); return cb
}
var times: [Double] = []
let lock = NSLock()
let start = Date()
if mode == "pipe" {
    let sem = DispatchSemaphore(value: 3)
    while Date().timeIntervalSince(start) < secs {
        sem.wait(); let cb = make()
        cb.addCompletedHandler { c in lock.lock(); times.append(c.gpuEndTime - c.gpuStartTime); lock.unlock(); sem.signal() }
        cb.commit()
    }
    for _ in 0..<3 { sem.wait() }; for _ in 0..<3 { sem.signal() }
} else if mode == "serial" {
    while Date().timeIntervalSince(start) < secs { let cb = make(); cb.commit(); cb.waitUntilCompleted(); times.append(cb.gpuEndTime - cb.gpuStartTime) }
} else {
    let duty = Double(a[3])!, period = 0.1
    while Date().timeIntervalSince(start) < secs {
        let ps = Date()
        while Date().timeIntervalSince(ps) < duty * period { let cb = make(); cb.commit(); cb.waitUntilCompleted(); times.append(cb.gpuEndTime - cb.gpuStartTime) }
        let rest = period - Date().timeIntervalSince(ps); if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    }
}
let wall = Date().timeIntervalSince(start)
let s = times.sorted(); let med = s[s.count / 2]
print(String(format: "%@ iters=%d: %d dispatches, wall %.2fs, GPU busy %.1f%%, mean %.3f ms, median %.3f ms per dispatch, pid %d",
             mode, iters, times.count, wall, 100 * times.reduce(0, +) / wall, 1000 * times.reduce(0, +) / Double(times.count), 1000 * med, getpid()))
