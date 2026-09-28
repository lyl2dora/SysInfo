#!/bin/bash
# Review: per-process GPU time via the ioreg CLI (independent of the original agent's IOKit walk).
# prints "pid name totalAccumulatedGPUTime_ns" for every AGXDeviceUserClient
ioreg -r -c AGXDeviceUserClient -l -w0 | awk '
/"AppUsage"/ { line=$0; tot=0; while (match(line, /"accumulatedGPUTime"=[0-9]+/)) { s=substr(line, RSTART, RLENGTH); sub(/.*=/, "", s); tot+=s; line=substr(line, RSTART+RLENGTH) } }
/"IOUserClientCreator"/ { c=$0; sub(/.*= "/, "", c); sub(/"$/, "", c); print c "\t" tot; tot=0 }'
