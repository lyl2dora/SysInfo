#!/bin/bash
# PMP0/Energy power-bin histograms at idle and under own 18-thread load (killed on exit)
cd "$(dirname "$0")"
PIDS=(); trap 'for p in "${PIDS[@]}"; do kill $p 2>/dev/null; done' EXIT
echo "### idle"; ./ioreport_sub PMP0 Energy 1 2000
./smcdump keys PSTR PHPC PMVC 2>/dev/null
for i in $(seq 1 18); do yes > /dev/null & PIDS+=($!); done
sleep 5
echo "### 18x yes load"; ./ioreport_sub PMP0 Energy 1 2000
./smcdump keys PSTR PHPC PMVC 2>/dev/null
