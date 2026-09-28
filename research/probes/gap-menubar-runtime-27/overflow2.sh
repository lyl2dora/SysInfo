#!/bin/bash
# dynamic overflow run with AX snapshots of MenuBarAgent at 5s (initial), 11s (after shrink), 16.5s (after restore)
P=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-menubar-runtime-27
cd $P
./wd.sh 60 ./mbprobe.app/Contents/MacOS/mbprobe --mode view --n 8 --itemw 200 --secs 20 --shrink 8 > runs/overflow2.txt 2>&1 &
for t in 5 11 16.5; do
  if [ "$t" = 5 ]; then sleep 5; elif [ "$t" = 11 ]; then sleep 6; else sleep 5.5; fi
  echo "=== AX MenuBarAgent at t=$t"
  ./axdump 462 3 --full | grep -E "AXApplication/- title='mbprobe'|显示隐藏|Show hidden|^\s{4}\?/-" | sed -E 's/AXFunctionRowTopLevelElements.*//' 
  /usr/sbin/screencapture -x -R0,0,1920,30 shots/overflow2_t$t.png
done
wait
