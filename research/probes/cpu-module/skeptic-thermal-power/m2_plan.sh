#!/bin/zsh
# m2_plan.sh — skeptic-thermal-power 在 Mac Studio (M2 Max) 上的复测计划（ssh 恢复后执行）。只读 SMC/IOReport；负载 ≤60 s。
# 1) 同步 + 编译；2) 拉取 thermal-power 留在远端的窗口 2 被动记录（只读复制）；3) E 簇翻转测试 ui8↔ui12（40 s）；4) 开销（3 次）；5) EM 结构。
set -e
here=${0:A:h}; R=/tmp/sysinfo-cpu-research/skeptic-thermal-power; HOST=${REMOTE_HOST:?set REMOTE_HOST=user@host}
$here/remote.sh sync && $here/remote.sh build
scp -o BatchMode=yes "$HOST:/tmp/sysinfo-cpu-research/thermal-power/out/passive2_m2.csv" "$here/tp_passive2_m2.csv" || echo "passive2 不可取"
$here/remote.sh run "sysctl -n hw.model kern.osversion; ps -axo pcpu | awk '{s+=\$1} END {print \"pcpu\",s}'; $R/bin/sk_rec $R/out/etoggle_m2.csv 2 'Te0,Tp0,Tp1,PPSR,PSVR,PMVR,PZC0,VC0' 'idle:6,ui8:8,ui12:8,ui8:8,ui12:8,ui8:8,idle:6'"
scp -o BatchMode=yes "$HOST:$R/out/etoggle_m2.csv" "$here/etoggle_m2.csv"
$here/remote.sh run "for i in 1 2 3; do $R/bin/sk_cost 'Tp01,Tp05,Tp09,Tp0D,Tp0X,Tp0b,Tp0f,Tp0j,Tp1B,Tp1F,Tp1J,Tp1N,Tp1h,Tp1l,Tp1p,Tp1t,PSVR,PPSR,Te05' 30 250; done; $R/bin/sk_thermal_cost; $R/bin/sk_em_struct | head -12" > "$here/cost_m2.txt" 2>&1
python3 $here/e_toggle_analyze.py $here/etoggle_m2.csv ui8 ui12
[ -f $here/tp_passive2_m2.csv ] && python3 $here/m2_window_recheck.py $here/tp_passive2_m2.csv
