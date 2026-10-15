// 传感器校准的录制部分（CPU 模块设计 §5.5，D33）：本进程内施加分段负载，同时以 2 Hz 记录各簇占用和 SMC 读数。
//
// 只在用户明确要求时运行（诊断页的按钮先弹窗确认；CLI 需要 --yes）。负载全部在本进程内，结束即停（D18 的口径）：
// - CPU：按「簇大小」逐级加载 UI QoS 自旋线程，快档的簇在前，再逐级回落（M5：6→12→18→12→6，M4：5→10→14→10→5），每级 6 s；
// - GPU：一段 Metal 计算负载（排在 CPU 负载之前），CPU 保持空闲，用来区分对 GPU 敏感的键（SoC/GPU 区域）；
// - 总时长约 58 s，其中 CPU 负载 30 s、GPU 负载 12 s。

import Foundation
import Metal
import Synchronization
import SysModel

public enum Calibration {
    public struct Phase: Hashable, Sendable {
        public var name: String
        public var seconds: Double
        public var cpuThreads: Int
        public var gpu: Bool
    }

    /// 按拓扑生成分段计划。拓扑必须判定出核档。
    public static func plan(for topology: CPUTopology, stepSeconds: Double = 6) -> [Phase] {
        var steps: [Int] = []
        var total = 0
        for level in topology.perfLevels {
            for key in level.clusters {
                total += topology.clusters.first { $0.key == key }?.cpus.count ?? 0
                steps.append(total)
            }
        }
        let updown = steps + steps.dropLast().reversed()
        // GPU 段放在 CPU 负载之前：放在之后会赶上整体降温，GPU 段的升温被抵消（2026-10-15 M5 实测）。
        return [
            Phase(name: "idle", seconds: 6, cpuThreads: 0, gpu: false),
            Phase(name: "gpu", seconds: 12, cpuThreads: 0, gpu: true),
            Phase(name: "idle", seconds: 6, cpuThreads: 0, gpu: false),
        ]
            + updown.map { Phase(name: "ui\($0)", seconds: stepSeconds, cpuThreads: $0, gpu: false) }
            + [Phase(name: "idle", seconds: 4, cpuThreads: 0, gpu: false)]
    }

    /// 要记录的键：全部 T 开头的温度键，以及 flt 类型、P 或 R 开头的功耗类键。
    static func keysToRecord(_ smc: SMCReader) throws(SMCError) -> [SMCKeyInfo] {
        try smc.allKeys().compactMap { key -> SMCKeyInfo? in
            let name = key.description
            guard let info = try? smc.keyInfo(for: key) else { return nil }
            if name.hasPrefix("T"), ["flt ", "sp78", "ioft", "fpe2"].contains(info.dataType) { return info }
            if (name.hasPrefix("P") || name.hasPrefix("R")), info.dataType == "flt " { return info }
            return nil
        }
    }

    /// 运行校准并返回原始记录。`progress` 在每段开始时调用。
    public static func record(
        topology: CPUTopology, phases: [Phase], progress: (Phase) -> Void = { _ in }
    ) throws -> CalibrationRecording {
        let smc = SMCReader()
        try smc.open()
        let infos = try keysToRecord(smc)
        let clusters = topology.clusters.map(\.key)
        var rows: [CalibrationRecording.Row] = []
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var previousTicks = try? CPULoadCollector.readTicks().get()
        var deadline = start

        for phase in phases {
            progress(phase)
            let spinners = Spinners(count: phase.cpuThreads)
            let gpu = phase.gpu ? GPULoad.start() : nil
            let phaseEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(phase.seconds * 1e9)
            while true {
                deadline += 500_000_000
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if deadline > now { usleep(UInt32((deadline - now) / 1000)) }
                let ticks = try? CPULoadCollector.readTicks().get()
                var utilization = [Double?](repeating: nil, count: clusters.count)
                if let previousTicks, let ticks, case .usage(let usage) = CPUTickMath.delta(previous: previousTicks, current: ticks) {
                    for (i, cluster) in topology.clusters.enumerated() {
                        utilization[i] = usage.aggregate(cores: cluster.cpus)?.busy
                    }
                }
                previousTicks = ticks
                var values: [Double?] = []
                values.reserveCapacity(infos.count)
                for info in infos {
                    values.append((try? smc.readRaw(info)).flatMap { SMCDecoder.decode(info, bytes: $0) })
                }
                let t = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
                rows.append(.init(t: t, phase: phase.name, utilization: utilization, gpuOn: phase.gpu, values: values))
                if clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= phaseEnd { break }
            }
            spinners.stop()
            gpu?.stop()
        }
        return CalibrationRecording(
            socID: ChipIdentity.socID(), osBuild: SystemInfo.osBuild, modelIdentifier: SystemInfo.modelIdentifier,
            topology: topology, clusters: clusters, keys: infos.map(\.key.description), rows: rows)
    }

    /// 本进程内的 UI QoS 自旋线程。只结束自己创建的线程。
    final class Spinners: Sendable {
        private let stopFlag = Atomic<Bool>(false)

        init(count: Int) {
            for _ in 0..<count {
                let thread = Thread { [self] in
                    var x: UInt64 = 1
                    while !self.stopFlag.load(ordering: .relaxed) {
                        for _ in 0..<20_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
                    }
                    if x == 42 { print(x) }
                }
                thread.qualityOfService = .userInteractive
                thread.start()
            }
        }

        func stop() {
            stopFlag.store(true, ordering: .relaxed)
        }
    }

    /// Metal 计算负载（移植自 skeptic-thermal-power/sk_gpu_load.swift）：反复提交 FMA 密集的 kernel，直到 stop()。
    final class GPULoad: Sendable {
        private let stopFlag = Atomic<Bool>(false)

        static func start() -> GPULoad? {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: source, options: nil),
                let function = library.makeFunction(name: "burn"),
                let pipeline = try? device.makeComputePipelineState(function: function),
                let buffer = device.makeBuffer(length: (1 << 20) * 4, options: .storageModePrivate)
            else { return nil }
            let load = GPULoad()
            let box = MetalBox(queue: queue, pipeline: pipeline, buffer: buffer)
            let thread = Thread { [load] in
                while !load.stopFlag.load(ordering: .relaxed) {
                    guard let commands = box.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
                    else { break }
                    encoder.setComputePipelineState(box.pipeline)
                    encoder.setBuffer(box.buffer, offset: 0, index: 0)
                    encoder.dispatchThreads(
                        MTLSize(width: 1 << 20, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: box.pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
                    encoder.endEncoding()
                    commands.commit()
                    commands.waitUntilCompleted()
                }
            }
            thread.start()
            return load
        }

        func stop() {
            stopFlag.store(true, ordering: .relaxed)
        }

        /// Metal 对象只在负载线程上使用。
        private struct MetalBox: @unchecked Sendable {
            let queue: any MTLCommandQueue
            let pipeline: any MTLComputePipelineState
            let buffer: any MTLBuffer
        }

        private static let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void burn(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {
              float a = float(id) * 1e-6, b = 1.0001, c = 0.9999;
              for (int i = 0; i < 4096; i++) { a = fma(a, b, c); b = fma(b, c, a * 1e-7); c = fma(c, a, 1e-7); }
              o[id] = a + b + c;
            }
            """
    }
}
