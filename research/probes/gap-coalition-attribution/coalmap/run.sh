#!/bin/sh
# driver: launch CoalMap.app in its own coalition via LaunchServices, and take `top` snapshots (from OUTSIDE the
# app's coalition, so top's own CPU is not attributed to it) every ~2 s until it exits.
D="$(cd "$(dirname "$0")" && pwd)"
TAG=${1:-run1}
rm -f "$D/coalmap_$TAG.txt" "$D/coalmap_${TAG}_err.txt"
open -n --stdout "$D/coalmap_$TAG.txt" --stderr "$D/coalmap_${TAG}_err.txt" "$D/CoalMap.app" --args "$D" ${2:-all}
sleep 1
: > "$D/top_phases_$TAG.txt"
while pgrep -f "CoalMap.app/Contents/MacOS/CoalMap" >/dev/null; do
  { echo "=== $(date +%H:%M:%S) top -l 2 -s 1 -o cpu -n 10 (2nd sample is the delta sample)"; /usr/bin/top -l 2 -s 1 -o cpu -n 10 -stats pid,command,cpu,power,idlew | sed -n '/^Processes/,$p' | tail -n 13; } >> "$D/top_phases_$TAG.txt"
done
echo "app exited"
