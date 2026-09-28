// Review helper: pure GPU ALU load via Metal for argv[1] seconds (no CPU spinning beyond command submission).
import Foundation
import Metal
let secs = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
let dev = MTLCreateSystemDefaultDevice()!
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float* out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
  float x = float(id) * 1e-6; for (int i = 0; i < 20000; i++) { x = fma(x, 1.0000001, 0.5); x = x * 0.9999999; } out[id] = x; }
"""
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let q = dev.makeCommandQueue()!; let n = 1 << 20; let buf = dev.makeBuffer(length: n * 4)!
let t0 = Date(); var k = 0
while Date().timeIntervalSince(t0) < secs { let cb = q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!; e.setComputePipelineState(pso); e.setBuffer(buf, offset: 0, index: 0)
  e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)); e.endEncoding(); cb.commit(); cb.waitUntilCompleted(); k += 1 }
print("gpu_burn: \(k) command buffers in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s on \(dev.name)")
