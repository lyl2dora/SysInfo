// gpuload.swift - self-terminating Metal compute load (default 25 s) used only to see which SMC Tg* keys / power keys track the GPU.
// Build: xcrun swiftc -O gpuload.swift -o gpuload ; Run: ./gpuload [seconds]
import Metal
import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "25") ?? 25
guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { print("no Metal"); exit(1) }
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float a = buf[id], b = 1.0001f, c = 0.9999f;
    for (int i = 0; i < 4096; i++) { a = fma(a, b, c); b = fma(b, c, a) * 0.5f; c = fma(c, a, b) * 0.5f; }
    buf[id] = a + b + c;
}
"""
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let n = 1 << 22
let buf = dev.makeBuffer(length: n * 4, options: .storageModePrivate)!
print("GPU: \(dev.name), running \(seconds)s")
let end = Date().addingTimeInterval(seconds)
var passes = 0
while Date() < end {
    let cb = q.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted(); passes += 1
}
print("done, passes=\(passes)")
