#!/bin/bash
# own 18x `yes` load for 25 s (PIDs tracked, killed explicitly), SMC sampled every 2 s from 6 s before to 16 s after
cd "$(dirname "$0")"
PIDS=(); trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT
./smcraw watch 25 2000 Tp00 Tp0K Tp0O Tp0y TVD0 TCMb Tg0U TH0x PSTR PDTR PHPC F0Ac F0Tg F0Dc > load_test.txt &
W=$!
sleep 6
for i in $(seq 1 18); do yes > /dev/null & PIDS+=($!); done
echo "load start $(date +%T) pids ${PIDS[*]}" > load_test.meta
sleep 25
for p in "${PIDS[@]}"; do kill "$p"; done; PIDS=()
echo "load end $(date +%T)" >> load_test.meta
wait $W
