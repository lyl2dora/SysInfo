#!/bin/bash
# wd.sh <limit_secs> <cmd...> : run cmd, kill it (own child only) if it exceeds limit
limit=$1; shift
"$@" & pid=$!
( sleep "$limit"; if kill -0 $pid 2>/dev/null; then echo "WATCHDOG: killing own pid $pid after ${limit}s"; kill $pid; fi ) & wdp=$!
wait $pid; rc=$?
kill $wdp 2>/dev/null
exit $rc
