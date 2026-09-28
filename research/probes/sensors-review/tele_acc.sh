#!/bin/zsh
# 1 Hz: epoch, SMC PDTR, and AppleSmartBattery PowerTelemetryData accumulator (via ioreg CLI) for N seconds
D=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/sensors-review
N=${1:-150}
for i in $(seq 1 $N); do
  e=$(date +%s)
  p=$($D/smcraw keys PDTR | awk '{print $NF}')
  a=$(ioreg -r -c AppleSmartBattery -w0 -a 2>/dev/null | plutil -extract 0.PowerTelemetryData json -o - - 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["AccumulatedSystemPowerIn"], d["SystemPowerInAccumulatorCount"], d["SystemPowerIn"])')
  echo "$e $p $a"
  sleep 0.75
done
