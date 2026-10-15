// sk_gpu_load.swift — 独立的 Metal 计算负载（skeptic-thermal-power）：在给定秒数内反复提交 FMA 密集的 compute kernel，然后退出。
// 用法：sk_gpu_load <秒数（≤60）>
import Metal
import Foundation
let secs = min(60.0, Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20)
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {
  float a = float(id) * 1e-6, b = 1.0001, c = 0.9999;
  for (int i = 0; i < 4096; i++) { a = fma(a, b, c); b = fma(b, c, a * 1e-7); c = fma(c, a, 1e-7); }
  o[id] = a + b + c;
}
"""
guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("no metal") }
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let n = 1 << 20
let buf = dev.makeBuffer(length: n * 4, options: .storageModePrivate)!
let q = dev.makeCommandQueue()!
let t0 = Date(); var k = 0
while Date().timeIntervalSince(t0) < secs {
  let cb = q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!
  e.setComputePipelineState(pso); e.setBuffer(buf, offset: 0, index: 0)
  e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
  e.endEncoding(); cb.commit(); cb.waitUntilCompleted(); k += 1
}
print("GPU 负载结束：\(k) 次提交，\(String(format: "%.1f", Date().timeIntervalSince(t0))) s，设备 \(dev.name)")
