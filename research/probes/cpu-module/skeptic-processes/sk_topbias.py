#!/usr/bin/env python3
# sk_topbias.py - 复核「top 的 %CPU 列对忙进程系统性偏低」：同一窗口里比较 top -l 2 -s W 第 2 个样本的 %CPU 与 setuid ps 的 TIME 差分。
# 在 top 打印每个样本表头（Processes:）时各取一次 ps 快照。不制造负载；可选 burn N 线程 T 秒（≤60 s）作为已知负载。
# 用法：sk_topbias.py [W=5] [burn_threads=0] [burn_secs=0]
import subprocess, sys, time, re, threading, os
W = int(sys.argv[1]) if len(sys.argv) > 1 else 5
nb = int(sys.argv[2]) if len(sys.argv) > 2 else 0
bs = int(sys.argv[3]) if len(sys.argv) > 3 else 0

def ps_snap():
    out = subprocess.run(["/bin/ps", "-axo", "pid=,time=,comm="], capture_output=True, text=True).stdout
    d = {}
    for ln in out.splitlines():
        f = ln.split(None, 2)
        if len(f) < 2: continue
        p = f[1].split(":")
        try:
            s = float(p[-1]) + 60 * float(p[-2]) + (3600 * float(p[-3]) if len(p) == 3 else 0)
        except ValueError:
            continue
        d[int(f[0])] = (s, os.path.basename(f[2]) if len(f) > 2 else "?")
    return d

burn = None
BURN = os.environ.get("SK_BURN")  # 若设置，则用 sk_burn 代替 yes：SK_BURN="/path/sk_burn N T churn_ms"
if BURN:
    burn = subprocess.Popen(BURN.split()); time.sleep(1)
elif nb and bs:
    burn = subprocess.Popen(["/bin/sh", "-c", " & ".join(["/usr/bin/yes > /dev/null"] * nb) + f" & sleep {bs}; kill $(jobs -p) 2>/dev/null"])
    time.sleep(1)
top = subprocess.Popen(["/usr/bin/top", "-l", "2", "-s", str(W), "-stats", "pid,cpu,time,command"], stdout=subprocess.PIPE, text=True)
snaps, ts, rows, hdr = [], [], {}, 0
for ln in top.stdout:
    if ln.startswith("Processes:"):
        hdr += 1; snaps.append(ps_snap()); ts.append(time.monotonic())
    elif hdr == 2:
        m = re.match(r"\s*(\d+)\s+([\d.]+)\s+(\S+)\s+(.*)", ln)
        if m: rows[int(m.group(1))] = float(m.group(2))
top.wait()
if burn: burn.wait()
dt = ts[1] - ts[0]
a, b = snaps
res = []
for pid, cpu in rows.items():
    if pid in a and pid in b:
        ref = 100 * (b[pid][0] - a[pid][0]) / dt
        if ref >= 20 or cpu >= 20:
            res.append((ref, cpu, pid, b[pid][1]))
print(f"# window {dt:.2f} s (top -s {W}); burn: {nb} x yes for {bs} s" if nb else f"# window {dt:.2f} s (top -s {W}); no own load")
print(f"   {'pid':>6} {'ps dTIME%':>10} {'top %CPU':>9} {'top/ps':>7}  command")
for ref, cpu, pid, name in sorted(res, reverse=True):
    print(f"   {pid:6d} {ref:10.1f} {cpu:9.1f} {cpu / ref if ref else 0:7.3f}  {name}")
