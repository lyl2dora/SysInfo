#!/bin/zsh
# every 5 s for 180 s: ioreg AppleSmartBattery PowerTelemetryData (CLI, different path than IORegistryEntryCreateCFProperty) vs SMC PDTR/VD0R/ID0R
D=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/sensors-review
for i in $(seq 1 36); do
  t=$(date +%T)
  tel=$(ioreg -r -c AppleSmartBattery -w0 -a 2>/dev/null | plutil -extract 0.PowerTelemetryData json -o - - 2>/dev/null)
  smc=$($D/smcraw keys PDTR VD0R ID0R | awk '{printf "%s=%s ", $1, $NF}')
  echo "$t SMC: $smc | TELE: $tel"
  sleep 5
done
