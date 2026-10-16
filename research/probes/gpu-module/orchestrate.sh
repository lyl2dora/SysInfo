#!/bin/bash
# orchestrate.sh - GPU 与加速器补测编排：启动 gpu_watch，等到第一个 PMGR 批次边界 T1，
# 在 T1 之后的 30 分钟窗口里依次跑负载（每段 ≤60 s，段间空闲 ≥60 s），等到第二个批次边界 T2 后再记 60 s 结束。
# 窗口内的 ANE / AVE / GPU 批次值用来与 coalition 槽位 39 / IRQ / AGX 对账。只结束自己派生的进程（D18）。
# usage: orchestrate.sh <dir> <tag>   （dir 里要有 build.sh 编出的程序）
set -u
D=$1; TAG=$2; cd "$D"
NCPU=$(sysctl -n hw.ncpu)
LOG=$D/phases_$TAG.log
now(){ python3 -c 'import time;print("%.3f"%time.time())'; }
echo "ORCH_START $(now) ncpu=$NCPU" > $LOG
./gpu_watch $D/gw_$TAG 3900 2> $D/gw_$TAG.stderr &
GW=$!
batches(){ local n; n=$(grep -cE '^=== [0-9.]+ CHANGE nchanged=[3-9]' $D/gw_${TAG}_pmgr.txt 2>/dev/null); echo ${n:-0}; }
for i in $(seq 1 1860); do [ "$(batches)" -ge 1 ] && break; sleep 1; done
T1=$(date +%s); echo "BATCH1 $(now)" >> $LOG
phase(){ local name=$1 off=$2; shift 2
  while [ $(date +%s) -lt $((T1+off)) ]; do sleep 0.5; done
  echo "PHASE_START $name $(now)" >> $LOG
  ./runm $name "$@" > $D/load_${TAG}_$name.txt 2>&1
  echo "PHASE_END $name $(now)" >> $LOG; }
phase gpu_full     60 ./rload pipe 45 16000
phase gpu_duty25  170 ./rload duty 30 0.25 2000
phase gpu_duty50  260 ./rload duty 30 0.5 2000
# runm 用 execv，不能经 env 启动；THREADS 由外层环境传入（2026-10-16 首轮因此缺了这一段，改用 tiny.sh 补测）
THREADS=256 phase gpu_tiny 350 ./rload pipe 30 2000000
phase gpu_render  440 ./gpuload_r render 30
# CPU + GPU 同时满载
while [ $(date +%s) -lt $((T1+540)) ]; do sleep 0.5; done
echo "PHASE_START cpu_gpu $(now)" >> $LOG
./runm cpu_gpu_g ./rload pipe 45 16000 > $D/load_${TAG}_cpu_gpu_g.txt 2>&1 &
G=$!
./runm cpu_gpu_c ./cpuburn $NCPU 45 ui > $D/load_${TAG}_cpu_gpu_c.txt 2>&1
wait $G
echo "PHASE_END cpu_gpu $(now)" >> $LOG
phase ane4        720 ./aneload2 45 4
phase hevc        900 ./mediaload hevc 30
phase decode      990 ./mediaload decode 30
phase prores     1080 ./mediaload prores 30
phase h264       1170 ./mediaload h264 30
phase ane1       1290 ./aneload2 30 1
while [ $(date +%s) -lt $((T1+1900)) ]; do [ "$(batches)" -ge 2 ] && break; sleep 1; done
echo "BATCH2 $(now)" >> $LOG
sleep 60
kill $GW 2>/dev/null; wait $GW 2>/dev/null
echo "ORCH_END $(now)" >> $LOG
