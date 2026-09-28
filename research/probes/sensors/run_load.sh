#!/bin/bash
# Samples selected SMC keys + HID temps at idle, under an 18-thread CPU load (own `yes` processes, killed on exit), and after.
cd "$(dirname "$0")"
KEYS="Tp00 Tp04 Tp0K Tp0O Tp0y Tp1E Ts00 Ts0a Tg0U Tg1c Tm0p Tm1p TCMb TVmS TH0x TW0P TR0Z PSTR PDTR PHPC PPSM PZC0 PZC1 PMVC Pb0f VD0R ID0R F0Ac F0Tg F0Dc F0md F0St"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
echo "### IDLE $(date +%T)"
./smcdump sample 2 1000 $KEYS 2>/dev/null
./hidsensors read 1 | sed -n '/temperature/,/current/p' | grep -E "tdie1 |tdie8 |NAND|tcal |tdev1 "
echo "### LOAD start $(date +%T): 18x yes"
for i in $(seq 1 18); do yes > /dev/null & PIDS+=($!); done
sleep 20
echo "### LOAD +20s $(date +%T)"
./smcdump sample 2 1000 $KEYS 2>/dev/null
./hidsensors read 1 | sed -n '/temperature/,/current/p' | grep -E "tdie1 |tdie8 |NAND|tcal |tdev1 "
cleanup; PIDS=()
echo "### LOAD stopped $(date +%T); recovery +15s"
sleep 15
./smcdump sample 1 0 $KEYS 2>/dev/null
echo "### remaining yes procs: $(pgrep -x yes | wc -l)"
