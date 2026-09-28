#!/bin/bash
# overflow.sh <mode> <n> <itemw> <label>
P=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-menubar-runtime-27
cd $P
mode=$1; n=$2; w=$3; label=$4
./wd.sh 60 ./mbprobe.app/Contents/MacOS/mbprobe --mode $mode --n $n --itemw $w --secs 22 --color --shots $P/shots --report 5 --swizzle > runs/overflow_$label.txt 2>&1 &
sleep 7
pid=$(pgrep -f "mbprobe --mode $mode --n $n --itemw")
echo "probe pid=$pid"
./axdump 462 3 --full > runs/overflow_${label}_ax_mba.txt 2>&1
./axdump $pid 3 --full > runs/overflow_${label}_ax_self.txt 2>&1
/usr/sbin/screencapture -x -R0,0,1920,30 shots/overflow_${label}_full.png
wait
