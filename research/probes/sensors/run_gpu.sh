#!/bin/bash
# idle snapshot, then 25 s Metal load (self-terminating), snapshot at +20 s; compare.
cd "$(dirname "$0")"
TG=$(awk 'NR>2 && ($2 ~ /^Tg/ || $2 ~ /^Ts/ || $2 ~ /^Tp/ || $2 ~ /^Ta/ || $2 ~ /^Tm0/ || $2=="TCMb" || $2=="PSTR" || $2=="PHPC" || $2=="PMVC" || $2=="PZC0" || $2=="PZC1" || $2=="PZD1" || $2=="PN00" || $2=="Pb0f" || $2=="PHPM" || $2=="PPSM" || $2=="PDTR") {print $2}' smc_dump.txt)
./smcdump keys $TG 2>/dev/null > smc_gpu_test_idle.txt
./gpuload 25 > gpuload_run.txt 2>&1 & GP=$!
sleep 20
./smcdump keys $TG 2>/dev/null > smc_gpu_test_load.txt
wait $GP
paste <(awk '{print $1, $NF}' smc_gpu_test_idle.txt) <(awk '{print $NF}' smc_gpu_test_load.txt) | awk '{printf "%-6s idle=%-9s gpuload=%-9s delta=%+.2f\n", $1, $2, $3, $3-$2}' > smc_gpu_test_compare.txt
