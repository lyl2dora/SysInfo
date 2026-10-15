#!/usr/bin/env python3
"""m2_perwatt.py — 以「功率」而不是占用做自变量，估计 M2 各温度键对 E 簇 / P 簇 / GPU 的每瓦敏感度（°C/W）。
自变量（均做 τ 秒一阶平滑，模拟热惯性）：E = PPSR − 0.034·GPU（E 簇主导轨），P = PSVR − GPU（P 簇），G = AGX GPU 功率。
每个文件单独去均值后拼接，避免文件间基线漂移。
用法：m2_perwatt.py a.csv [...] [--tau 3]"""
import csv, sys, math, argparse
import numpy as np
ap = argparse.ArgumentParser(); ap.add_argument('csv', nargs='+'); ap.add_argument('--tau', type=float, default=3.0); a = ap.parse_args()
Xs = []; Ys = {}
def sm(x):
    al = 1 - math.exp(-1 / a.tau); s = np.empty_like(x); acc = x[0]
    for i, v in enumerate(x): acc += al * (v - acc); s[i] = acc
    return s
for fn in a.csv:
    rows = list(csv.reader(open(fn))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}; R = rows[1:]
    col = lambda k: np.array([float(r[ix[k]]) for r in R])
    G = col('EM:GPU Energy'); E = col('PPSR') - 0.034 * G; P = col('PSVR') - G
    X = np.column_stack([sm(E), sm(P), sm(G)]); X -= X.mean(0); Xs.append(X)
    for k in h:
        if len(k) == 4 and k[0] == 'T':
            y = col(k); Ys.setdefault(k, []).append(y - y.mean())
X = np.vstack(Xs); Y = {k: np.concatenate(v) for k, v in Ys.items() if len(v) == len(a.csv)}
print(f"N={len(X)}；E 功率范围 {np.ptp(X[:,0]):.2f} W，P {np.ptp(X[:,1]):.1f} W，GPU {np.ptp(X[:,2]):.1f} W")
out = []
for k, y in Y.items():
    if np.ptp(y) < 0.5: continue
    b, *_ = np.linalg.lstsq(X, y, rcond=None); r2 = 1 - ((y - X @ b) ** 2).mean() / y.var()
    out.append((b[0] / max(abs(b[1]), 1e-3), k, b, r2))
out.sort(reverse=True)
print("按「E 每瓦敏感度 / P 每瓦敏感度」排序前 15：")
for ratio, k, b, r2 in out[:15]:
    print(f"  {k}: E {b[0]:+.2f} °C/W  P {b[1]:+.3f} °C/W  GPU {b[2]:+.3f} °C/W  E/P={ratio:6.1f}  R2={r2:.2f}")
for ratio, k, b, r2 in out:
    if k in ('Tp01', 'Tp1J', 'TCMb', 'Tf04', 'Te04', 'Te05', 'Te06', 'TRDX', 'TPDX'):
        print(f"  参照 {k}: E {b[0]:+.2f}  P {b[1]:+.3f}  GPU {b[2]:+.3f}  R2={r2:.2f}")
