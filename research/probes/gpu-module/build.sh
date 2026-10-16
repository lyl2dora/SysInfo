#!/bin/bash
# build.sh <outdir> - 编译 GPU 与加速器模块边界复核所需的探针与负载程序（负载程序沿用 power-thermal/、gpu/、gpu-review/）
set -e; O=$1; mkdir -p $O; S=$(cd "$(dirname "$0")"; pwd); P=$S/..
xcrun clang -O2 -o $O/gpu_struct $S/gpu_struct.c -lIOReport -framework IOKit -framework CoreFoundation
xcrun clang -O2 -o $O/gpu_watch $S/gpu_watch.c -lIOReport -framework IOKit -framework CoreFoundation
xcrun clang -O2 $P/power-thermal/runm.c -o $O/runm
xcrun clang -O2 $P/power-thermal/cpuburn.c -o $O/cpuburn
xcrun swiftc -O -o $O/rload $P/gpu-review/rload.swift -framework Metal
xcrun swiftc -O -o $O/gpuload_r $P/gpu/gpuload.swift -framework Metal
xcrun swiftc -O -o $O/aneload2 $P/power-thermal/aneload2.swift -framework Vision -framework CoreML -framework CoreGraphics
xcrun swiftc -O -o $O/mediaload $P/power-thermal/mediaload.swift -framework VideoToolbox -framework CoreMedia -framework CoreVideo
cp $S/orchestrate.sh $S/tiny.sh $O/
xcrun clang -O2 -Wno-multichar -o $O/costbench_gpu $S/costbench_gpu.c -lIOReport -framework IOKit -framework CoreFoundation
