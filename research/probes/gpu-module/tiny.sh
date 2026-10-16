#!/bin/bash
# tiny.sh <dir> <tag>：gpu_watch 记 50 s，第 10–40 s 跑单线程组规模的小 kernel（THREADS=256）
D=$1; TAG=$2; cd "$D"
./gpu_watch $D/gwt_$TAG 50 2> $D/gwt_$TAG.stderr &
GW=$!; sleep 10
echo "PHASE_START gpu_tiny $(python3 -c 'import time;print("%.3f"%time.time())')" > $D/phases_t_$TAG.log
THREADS=256 ./rload pipe 30 2000000 > $D/load_t_$TAG.txt 2>&1
echo "PHASE_END gpu_tiny $(python3 -c 'import time;print("%.3f"%time.time())')" >> $D/phases_t_$TAG.log
wait $GW
