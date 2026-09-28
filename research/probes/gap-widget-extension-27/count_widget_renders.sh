#!/bin/zsh
# Usage (after placing the Stats CPU widget on the desktop and leaving Stats running for N minutes):
#   ./count_widget_renders.sh 30m
# Counts, for zone.lyl.stats: host reload requests, chronod reload decisions/throttles, extension launches, and real renders.
W=${1:-30m}
L=/usr/bin/log; TMPF=$(mktemp -t stats_renders)
echo "== host reloadTimelines calls (Stats -> chronod)"
$L show --last $W --style compact --predicate 'process == "Stats" AND subsystem == "com.apple.chrono" AND eventMessage CONTAINS "reloadTimelines"' | grep -c reloadTimelines
echo "== chronod ignored (no placed/known extension)"
$L show --last $W --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "restricted or unknown extension zone.lyl.stats"' | grep -c Ignoring
echo "== chronod timeline reloads actually scheduled for Stats widgets (budgeted/free), and throttles"
$L show --last $W --info --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "zone.lyl.stats" AND (eventMessage CONTAINS "scheduled [" OR eventMessage CONTAINS "Throttl" OR eventMessage CONTAINS "throttle" OR eventMessage CONTAINS "Reload requested")' | tee /dev/stderr | grep -c "scheduled \["
echo "== WidgetsExtension process launches"
$L show --last $W --info --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "Launching process with config" AND eventMessage CONTAINS "zone.lyl.stats.Widgets"' | grep -c "Launching process" 
$L show --last $W --style compact --predicate 'process == "WidgetsExtension"' | head -3
echo "== real renders in the widget host (NotificationCenter renders desktop widgets)"
$L show --last $W --style compact --predicate 'process == "NotificationCenter" AND category == "timelineLiveView" AND eventMessage CONTAINS "zone.lyl.stats" AND eventMessage CONTAINS "Evaluated inner view"' | tee $TMPF | grep -c "Evaluated inner view"
sed -E 's/.*result: ([A-Z]+).*reasons: (.*)$/\1 \2/' $TMPF | sort | uniq -c; rm -f $TMPF
