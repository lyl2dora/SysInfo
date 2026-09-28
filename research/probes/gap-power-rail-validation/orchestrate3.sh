#!/bin/bash
# orchestrate2.sh - third window (19:08:29 -> 19:38:29): M-cluster, ANE and AVE heavy mix; own processes only.
D=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-power-rail-validation
cd $D
ep(){ date -j -f '%Y-%m-%d %H:%M:%S' "2026-09-28 $1" +%s; }
until_t(){ local tgt=$(ep $1); while [ $(date +%s) -lt $tgt ]; do sleep 0.5; done; }
snap(){ top -l 2 -s 1 -o cpu -n 12 -stats pid,command,cpu,power,time > $D/top_$1.txt 2>&1; }
phase(){ local name=$1 st=$2; shift 2; until_t $st
  echo "PHASE_START $name $(python3 -c 'import time;print("%.3f"%time.time())') $st" >> $D/phases3.log
  ( sleep 25; snap $name ) &
  $D/runm $name "$@" > $D/load_$name.txt 2>&1
  echo "PHASE_END $name $(date +%s)" >> $D/phases3.log; }
echo "ORCH_START $(date +%s)" >> $D/phases3.log
phase w3_bg12    19:10:00 $D/cpuburn 12 150 bg
phase w3_gpu     19:14:00 $D/gpuload load 90
phase w3_ane     19:17:00 $D/aneload2 150 4
phase w3_hevc    19:21:00 $D/mediaload hevc 150
phase w3_dram    19:25:00 $D/dram 6 45
phase w3_super6  19:27:00 $D/cpuburn 6 60 ui
until_t 19:30:00; snap w3_idle_post
echo "ORCH_END $(date +%s)" >> $D/phases3.log
