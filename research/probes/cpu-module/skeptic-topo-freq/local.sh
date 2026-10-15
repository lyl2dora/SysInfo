#!/bin/zsh
# 本机编译并运行：./local.sh <probe.c> [运行参数...]（二进制放在 /tmp 下，不进仓库）
set -e
src=$1; shift
B=${TMPDIR:-/tmp}/skeptic-topo-freq-bin; mkdir -p $B
clang -O2 -Wall -Wno-unused -o $B/${src:t:r} $src -framework IOKit -framework CoreFoundation -lIOReport
$B/${src:t:r} "$@"
