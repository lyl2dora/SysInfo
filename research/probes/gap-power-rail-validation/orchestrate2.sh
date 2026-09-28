#!/bin/bash
# orchestrate2.sh - second window (18:38:29 -> 19:08:29) with a different load mix (ANE/AVE/GPU-heavy); own processes only.
D=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-power-rail-validation
cd $D
ep(){ date -j -f '%Y-%m-%d %H:%M:%S' "2026-09-28 $1" +%s; }
until_t(){ local tgt=$(ep $1); while [ $(date +%s) -lt $tgt ]; do sleep 0.5; done; }
snap(){ top -l 2 -s 1 -o cpu -n 12 -stats pid,command,cpu,power,time > $D/top_$1.txt 2>&1; }
phase(){ local name=$1 st=$2; shift 2; until_t $st
  echo "PHASE_START $name $(python3 -c 'import time;print("%.3f"%time.time())') $st" >> $D/phases2.log
  ( sleep 25; snap $name ) &
  $D/runm $name "$@" > $D/load_$name.txt 2>&1
  echo "PHASE_END $name $(date +%s)" >> $D/phases2.log; }
echo "ORCH_START $(date +%s)" >> $D/phases2.log
phase w2_ane     18:48:30 $D/aneload2 240 4
phase w2_hevc    18:53:30 $D/mediaload hevc 180
phase w2_gpu     18:57:30 $D/gpuload load 120
phase w2_dram    19:00:30 $D/dram 6 60
phase w2_super6  19:02:30 $D/cpuburn 6 120 ui
until_t 19:06:00; snap w2_idle_post
echo "ORCH_END $(date +%s)" >> $D/phases2.log
