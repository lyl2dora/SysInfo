#!/bin/bash
cd "$(dirname "$0")"
K=$(awk 'NR>2 && ($2 ~ /^Tp/ || $2 ~ /^Ts/ || $2 ~ /^Te/ || $2 ~ /^Tf/) {print $2}' smc_dump.txt)
snap() { ./smcdump keys $K 2>/dev/null | awk '{print $1, $NF}'; }
for mode in bg ui; do
  sleep 25
  snap > qos_$mode.idle
  ./qosburn $([ $mode = bg ] && echo 12 || echo 6) 25 $mode > qos_$mode.run &
  P=$!; sleep 20; snap > qos_$mode.load; ps -M -p $P > qos_$mode.ps 2>/dev/null; wait $P
  paste qos_$mode.idle qos_$mode.load | awk -v m=$mode '{printf "%s %-5s idle=%-8s load=%-8s d=%+.2f\n", m, $1, $2, $4, $4-$2}'
done
