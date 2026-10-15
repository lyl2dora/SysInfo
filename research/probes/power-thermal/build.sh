#!/bin/bash
# build.sh <outdir> - 编译补测所需的探针
set -e; O=$1; mkdir -p $O; S=$(cd "$(dirname "$0")"; pwd)
xcrun clang -O2 -framework IOKit -framework CoreFoundation -lIOReport $S/ptlog.c -o $O/ptlog
xcrun clang -O2 $S/runm.c -o $O/runm
xcrun clang -O2 $S/cpuburn.c -o $O/cpuburn
xcrun clang -O2 $S/dram.c -o $O/dram
xcrun swiftc -O -o $O/gpuload $S/gpuload.swift -framework Metal
xcrun swiftc -O -o $O/aneload2 $S/aneload2.swift -framework Vision -framework CoreML -framework CoreGraphics
xcrun swiftc -O -o $O/mediaload $S/mediaload.swift -framework VideoToolbox -framework CoreMedia -framework CoreVideo
cp $S/orchestrate.sh $O/
