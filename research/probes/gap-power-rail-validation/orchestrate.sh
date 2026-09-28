#!/bin/bash
# orchestrate.sh - timed load phases inside the 18:08:29 -> 18:38:29 PMGR window. Own processes only; no sudo.
D=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-power-rail-validation
cd $D
ep(){ date -j -f '%Y-%m-%d %H:%M:%S' "2026-09-28 $1" +%s; }
until_t(){ local tgt=$(ep $1); while [ $(date +%s) -lt $tgt ]; do sleep 0.2; done; }
snap(){ top -l 2 -s 1 -o cpu -n 12 -stats pid,command,cpu,power,time > $D/top_$1.txt 2>&1; }
phase(){ # name start end cmd...
  local name=$1 st=$2 en=$3; shift 3
  until_t $st
  echo "PHASE_START $name $(python3 -c 'import time;print("%.3f"%time.time())' 2>/dev/null || date +%s) $st" >> $D/phases.log
  ( sleep 25; snap $name ) &
  $D/runm $name "$@" > $D/load_$name.txt 2>&1
  echo "PHASE_END $name $(date +%s) " >> $D/phases.log
  ( sleep 40; snap gap_after_$name ) &
}
echo "ORCH_START $(date +%s)" >> $D/phases.log
until_t 18:09:30; snap idle_pre
phase p1_super6   18:10:30 18:12:30 $D/cpuburn 6 120 ui
phase p2_all18    18:14:30 18:16:30 $D/cpuburn 18 120 def
phase p3_bg12     18:18:30 18:20:30 $D/cpuburn 12 120 bg
phase p4_gpu      18:22:30 18:24:30 $D/gpuload load 120
phase p5_ane      18:26:30 18:28:30 $D/aneload2 120 4
phase p6_dram     18:30:30 18:32:30 $D/dram 6 120
phase p7_hevc     18:34:00 18:36:00 $D/mediaload hevc 120
until_t 18:37:30; snap idle_post
echo "ORCH_END $(date +%s)" >> $D/phases.log
