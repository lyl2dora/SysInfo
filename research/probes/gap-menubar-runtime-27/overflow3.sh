#!/bin/bash
# overflow dropdown test: open MenuBarAgent's hidden-items chevron via AXPress while 8x200pt probe items exist
P=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-menubar-runtime-27
cd $P
./wd.sh 60 ./mbprobe.app/Contents/MacOS/mbprobe --mode image --n 8 --itemw 200 --color --secs 16 --report 2 --swizzle > runs/overflow3.txt 2>&1 &
sleep 6
echo "== t6 AX before"; ./axdump 462 3 --full | grep -E "显示隐藏|title='mbprobe'" | sed -E 's/AXFunctionRow.*//' | head -20
./axpress 462 "显示隐藏菜单栏项目"
sleep 1.5
/usr/sbin/screencapture -x -R0,0,1920,120 shots/overflow3_dropdown_open.png
echo "== t7.5 AX (dropdown open)"; ./axdump 462 4 --full | sed -E 's/AXFunctionRow.*//' | grep -v "AXMenuExtra\|AXHostingView" | cut -c1-200 | head -60
sleep 2.5
./axpress 462 "显示隐藏菜单栏项目"
sleep 1
/usr/sbin/screencapture -x -R0,0,1920,120 shots/overflow3_dropdown_closed.png
wait
