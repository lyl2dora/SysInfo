#!/bin/bash
# overflow dropdown test via a real click on MenuBarAgent's "show hidden items" chevron (position read from AX)
P=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-menubar-runtime-27
cd $P
./wd.sh 60 ./mbprobe.app/Contents/MacOS/mbprobe --mode image --n 8 --itemw 200 --color --secs 16 --report 1 --swizzle > runs/overflow4.txt 2>&1 &
sleep 5
line=$(./axdump 462 2 | grep -m1 "显示隐藏菜单栏项目")
echo "chevron: $line"
cx=$(echo "$line" | sed -E 's/.*\(([0-9]+),([0-9]+) ([0-9]+)x([0-9]+)\).*/\1 \3/' | awk '{print $1+$2/2}')
echo "cx=$cx"
if [ -n "$cx" ]; then
  ./click $cx 15
  sleep 1.5
  /usr/sbin/screencapture -x -R0,0,1920,140 shots/overflow4_dropdown_open.png
  echo "== AX while open"; ./axdump 462 4 --full | sed -E 's/AXFunctionRow.*//' | grep -v "AXMenuExtra\|AXHostingView" | cut -c1-200 | grep -v "^\s*?/- title='' desc='' id='' ([0-9]*,0 [0-9]*x30)$" | head -60
  sleep 2
  ./click $cx 15
  sleep 1
  /usr/sbin/screencapture -x -R0,0,1920,140 shots/overflow4_dropdown_closed.png
fi
wait
