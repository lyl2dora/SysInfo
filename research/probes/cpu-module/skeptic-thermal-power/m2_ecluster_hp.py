#!/usr/bin/env python3
"""m2_ecluster_hp.py — 去趋势后再看「只有 E 簇在变」时哪些键跟随 E 簇（排除开机后整体降温这类慢漂移造成的假相关）。
对每条长记录：键值与 util_c0 各减去 ±W 秒滑动中位数（高通），只取 P 簇与 GPU 空闲的秒，计算相关系数与回归斜率（°C 或 W / 单位 E 簇占用）。
同时对 util_c0 做 τ 秒一阶平滑（热惯性），并允许 0–3 s 滞后，取最大相关。
用法：m2_ecluster_hp.py a.csv [--win 60]
"""
import csv, sys, math, argparse
import numpy as np
ap = argparse.ArgumentParser(); ap.add_argument('csv', nargs='+'); ap.add_argument('--win', type=int, default=60); ap.add_argument('--tau', type=float, default=3.0)
a = ap.parse_args()
def movmed(x, w):
    n = len(x); out = np.empty(n)
    for i in range(n): out[i] = np.median(x[max(0, i - w):min(n, i + w + 1)])
    return out
res = {}
for fn in a.csv:
    rows = list(csv.reader(open(fn))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}
    def col(k):
        try: return np.array([float(r[ix[k]]) for r in rows[1:]])
        except: return None
    u0, u1, u2, g = col('util_c0'), col('util_c1'), col('util_c2'), col('EM:GPU Energy')
    al = 1 - math.exp(-1 / a.tau); s = np.empty_like(u0); acc = u0[0]
    for i, v in enumerate(u0): acc += al * (v - acc); s[i] = acc
    mask = (u1 < 0.03) & (u2 < 0.03) & (g < 1.0)
    # 只有 P 簇与 GPU 连续空闲 ≥ 10 s 的段落（避免 P 簇余热）
    ok = np.zeros(len(u0), bool); run = 0
    for i in range(len(u0)):
        run = run + 1 if mask[i] else 0
        ok[i] = run >= 10
    xs = s - movmed(s, a.win)
    for k in h:
        if not (len(k) == 4 and k[0] in 'TPV'): continue
        y = col(k)
        if y is None or np.isnan(y).any() or np.ptp(y) == 0: continue
        yh = y - movmed(y, a.win)
        best = None
        for lag in range(0, 4):
            xx = xs[:len(xs) - lag] if lag else xs; yy = yh[lag:]; m = ok[lag:]
            if m.sum() < 50 or xx[m].std() == 0 or yy[m].std() == 0: continue
            r = np.corrcoef(xx[m], yy[m])[0, 1]; b = np.polyfit(xx[m], yy[m], 1)[0]
            if best is None or abs(r) > abs(best[0]): best = (r, b, lag, int(m.sum()))
        if best: res.setdefault(k, []).append((fn.split('/')[-1], best))
out = sorted(res.items(), key=lambda kv: -np.mean([abs(b[0]) for _, b in kv[1]]))
print(f"高通窗口 ±{a.win} s，τ={a.tau} s；按平均 |r| 排序前 25：")
for k, lst in out[:25]:
    print(f"  {k}: " + '; '.join(f"{f}: r={b[0]:+.2f} 斜率={b[1]:+.3f} lag={b[2]} n={b[3]}" for f, b in lst))
