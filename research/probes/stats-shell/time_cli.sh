#!/bin/zsh
# Times the CLI tools Stats (v3.0.14) spawns from its readers. Read-only commands only.
t() { local label="$1"; shift; local s=$(perl -MTime::HiRes=time -e 'print time'); "$@" >/dev/null 2>&1; local e=$(perl -MTime::HiRes=time -e 'print time'); printf "%-60s %6.0f ms\n" "$label" $(( (e-s)*1000 )); }
for i in 1 2; do
echo "--- run $i"
t "ps -Aceo pid,pcpu,comm -r (CPU/Disk ProcessReader)" /bin/ps -Aceo pid,pcpu,comm -r
t "top -l 1 -o mem -n 8 (RAM ProcessReader)" /usr/bin/top -l 1 -o mem -n 8 -stats pid,command,mem
t "top -o power -l 2 -n 8 (Battery ProcessReader)" /usr/bin/top -o power -l 2 -n 8 -stats pid,command,power
t "nettop -P -L 1 -n (Net ProcessReader / process reader mode)" /usr/bin/nettop -P -L 1 -n -k time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch
t "uptime (CPU AverageLoadReader, every 15s)" /usr/bin/uptime
t "pmset -g accps -xml (Bluetooth reader, every tick)" /usr/bin/pmset -g accps -xml
t "system_profiler SPBluetoothDataType -json (Bluetooth, every tick)" /usr/sbin/system_profiler SPBluetoothDataType -json
t "system_profiler SPDisplaysDataType -json (SystemKit launch)" /usr/sbin/system_profiler SPDisplaysDataType -json
t "system_profiler SPMemoryDataType -json (SystemKit launch)" /usr/sbin/system_profiler SPMemoryDataType -json
t "system_profiler SPHardwareDataType -json (SystemKit launch; Mac17,16 not in deviceDict)" /usr/sbin/system_profiler SPHardwareDataType -json
t "diskutil list -plist (SystemKit launch)" /usr/sbin/diskutil list -plist
done
