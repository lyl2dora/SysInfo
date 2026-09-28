#!/bin/bash
# Sequential 120 s cost battery. Measures own CPU (rusage from probe), MenuBarAgent(462)/WindowServer(172)/Stats CPU deltas (ps TIME),
# and WindowServer/MenuBarAgent/probe log counts in each run window.
P=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/gap-menubar-runtime-27
cd $P
SECS=${SECS:-120}
BIN=./mbprobe.app/Contents/MacOS/mbprobe
OUT=runs/battery
mkdir -p $OUT
SUM=$OUT/summary.tsv
STATSPID=$(pgrep -x Stats | head -1)
tosec() { awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1 }' <<< "$1"; }
cput() { tosec "$(ps -o time= -p $1 2>/dev/null | tr -d ' ')"; }
echo -e "label\tsecs\tMBA_cpu_s\tWS_cpu_s\tStats_cpu_s\tprobe_cpu_s\tWS_invalid_window\tWS_other_err\tMBA_err\tMBA_info_lines\tprobe_err\tprobe_summary" > $SUM
run() {
  label=$1; shift
  sleep 5
  start=$(date '+%Y-%m-%d %H:%M:%S')
  m0=$(cput 462); w0=$(cput 172); s0=$(cput $STATSPID)
  if [ "$label" = base1 ] || [ "$label" = base2 ]; then
    sleep $SECS; ptxt="(no app)"; pcpu=0
    : > $OUT/$label.txt
  else
    ./wd.sh $((SECS+40)) $BIN "$@" --secs $SECS > $OUT/$label.txt 2>&1
    ptxt=$(grep -E "SUMMARY" $OUT/$label.txt | sed -E 's/^\[[ 0-9.]+\] //' | head -1)
    pcpu=$(echo "$ptxt" | sed -E 's/.*ownCPU=([0-9.]+)s.*/\1/')
  fi
  m1=$(cput 462); w1=$(cput 172); s1=$(cput $STATSPID)
  end=$(date '+%Y-%m-%d %H:%M:%S')
  sleep 2
  inv=$(/usr/bin/log show --start "$start" --end "$end" --predicate 'process == "WindowServer" AND eventMessage CONTAINS "Invalid window"' --style compact 2>/dev/null | grep -c "Invalid window")
  wse=$(/usr/bin/log show --start "$start" --end "$end" --predicate 'process == "WindowServer" AND messageType >= 16 AND NOT eventMessage CONTAINS "Invalid window" AND NOT eventMessage CONTAINS "SILServer" AND NOT eventMessage CONTAINS "indicator" AND NOT eventMessage CONTAINS "move_cursor"' --style compact 2>/dev/null | grep -c " E \| F ")
  mbe=$(/usr/bin/log show --start "$start" --end "$end" --predicate 'process == "MenuBarAgent" AND messageType >= 16' --style compact 2>/dev/null | grep -c " E \| F ")
  mbi=$(/usr/bin/log show --start "$start" --end "$end" --info --debug --predicate 'process == "MenuBarAgent"' --style compact 2>/dev/null | grep -c "MenuBarAgent\[")
  pe=$(/usr/bin/log show --start "$start" --end "$end" --predicate 'process == "mbprobe" AND messageType >= 16' --style compact 2>/dev/null | grep -c " E \| F ")
  /usr/bin/log show --start "$start" --end "$end" --predicate '(process == "WindowServer" AND NOT eventMessage CONTAINS "SILServer" AND NOT eventMessage CONTAINS "move_cursor") OR process == "MenuBarAgent" OR process == "mbprobe"' --style compact 2>/dev/null | sed -E 's/^[0-9-]+ [0-9:.]+ //; s/\[[0-9]+:[0-9a-f]+\]//; s/0x[0-9a-f]+/X/g; s/[0-9A-F]{8}-[0-9A-F-]{27}/UUID/g' | cut -c1-180 | sort | uniq -c | sort -rn | head -15 > $OUT/${label}_loghist.txt
  echo -e "$label\t$SECS\t$(echo "$m1 - $m0" | bc)\t$(echo "$w1 - $w0" | bc)\t$(echo "$s1 - $s0" | bc)\t$pcpu\t$inv\t$wse\t$mbe\t$mbi\t$pe\t$ptxt" | tee -a $SUM
}
run base1
run A1_image_n1 --mode image --n 1
run A4_image_n4 --mode image --n 4
run A8_image_n8 --mode image --n 8
run B1_view_n1 --mode view --n 1
run B4_view_n4 --mode view --n 4
run B8_view_n8 --mode view --n 8
run S4_subview_n4 --mode subview --n 4
run C_swiftui --mode swiftui
run D4_image_churn --mode image --n 4 --churn
run D4_view_churn --mode view --n 4 --churn
run A4p_image_n4_patch --mode image --n 4 --patch
run B4p_view_n4_patch --mode view --n 4 --patch
run D4p_image_churn_patch --mode image --n 4 --churn --patch
run Cp_swiftui_patch --mode swiftui --patch
run base2
echo BATTERY_DONE
