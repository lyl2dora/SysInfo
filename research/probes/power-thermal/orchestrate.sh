#!/bin/bash
# orchestrate.sh - 功耗与散热补测编排：先启动 ptlog，等到第一个 PMGR 批次边界 T1，
# 在 T1 之后的 30 分钟窗口里依次跑 7 段负载（每段 ≤60 s，段间空闲约 2 分钟），
# 等到第二个批次边界 T2 后再记 60 s，然后结束 ptlog。只结束自己派生的进程（D18）。
# 环境变量 ROUND=2 时跑第二轮（5 段：cpu_all/gpu/cpu_gpu/cpu_half/cpu_bg）。
# usage: orchestrate.sh <dir> <tag>   （dir 里要有已编译的 ptlog/runm/cpuburn/dram/gpuload/aneload2/mediaload）
set -u
D=$1; TAG=$2; cd "$D"
NCPU=$(sysctl -n hw.ncpu); HALF=$((NCPU/2))
LOG=$D/phases_$TAG.log
now(){ python3 -c 'import time;print("%.3f"%time.time())'; }
echo "ORCH_START $(now) ncpu=$NCPU" > $LOG
./ptlog $D/pt_$TAG 3900 2> $D/ptlog_$TAG.stderr &
PT=$!
batches(){ local n; n=$(grep -cE '^=== [0-9.]+ CHANGE nchanged=([2-9][0-9]|[0-9]{3,})' $D/pt_${TAG}_pmgr.txt 2>/dev/null); echo ${n:-0}; }
# 等第一个批次边界（最多 1860 s）
for i in $(seq 1 1860); do [ "$(batches)" -ge 1 ] && break; sleep 1; done
T1=$(date +%s); echo "BATCH1 $(now)" >> $LOG
phase(){ local name=$1 off=$2; shift 2
  while [ $(date +%s) -lt $((T1+off)) ]; do sleep 0.5; done
  echo "PHASE_START $name $(now)" >> $LOG
  ./runm $name "$@" > $D/load_${TAG}_$name.txt 2>&1
  echo "PHASE_END $name $(now)" >> $LOG; }
if [ "${ROUND:-1}" = 2 ]; then
phase cpu_all   120 ./cpuburn $NCPU 60 ui
phase gpu       300 ./gpuload load 60
while [ $(date +%s) -lt $((T1+480)) ]; do sleep 0.5; done
echo "PHASE_START cpu_gpu $(now)" >> $LOG
./runm cpu_gpu_g ./gpuload load 60 > $D/load_${TAG}_cpu_gpu_g.txt 2>&1 &
G=$!
./runm cpu_gpu_c ./cpuburn $NCPU 60 ui > $D/load_${TAG}_cpu_gpu_c.txt 2>&1
wait $G
echo "PHASE_END cpu_gpu $(now)" >> $LOG
phase cpu_half  720 ./cpuburn $HALF 60 ui
phase cpu_bg    900 ./cpuburn $NCPU 60 bg
else
phase cpu_all   120 ./cpuburn $NCPU 60 ui
phase gpu       300 ./gpuload load 60
phase dram      480 ./dram 6 45
phase ane       660 ./aneload2 60 4
phase hevc      840 ./mediaload hevc 60
# CPU + GPU 同时满载（看风扇、热点、热压力）
while [ $(date +%s) -lt $((T1+1020)) ]; do sleep 0.5; done
echo "PHASE_START cpu_gpu $(now)" >> $LOG
./runm cpu_gpu_g ./gpuload load 60 > $D/load_${TAG}_cpu_gpu_g.txt 2>&1 &
G=$!
./runm cpu_gpu_c ./cpuburn $NCPU 60 ui > $D/load_${TAG}_cpu_gpu_c.txt 2>&1
wait $G
echo "PHASE_END cpu_gpu $(now)" >> $LOG
phase cpu_half 1200 ./cpuburn $HALF 60 ui
fi
# 等第二个批次边界（最多到 T1+1900）
while [ $(date +%s) -lt $((T1+1900)) ]; do [ "$(batches)" -ge 2 ] && break; sleep 1; done
echo "BATCH2 $(now)" >> $LOG
sleep 60
kill $PT 2>/dev/null; wait $PT 2>/dev/null
echo "ORCH_END $(now)" >> $LOG
