#!/usr/bin/env python3
"""m2_ecluster_recheck.py — 复核「M2 E 簇没有可辨识温度/功耗键」（独立实现）。
在全部 M2 记录上，对每个 T/P/V/I 键做普通最小二乘：key ~ 1 + util_c0 + util_c1 + util_c2 + GPU，
报告 util_c0（E 簇）系数的 t 值与「E 簇 0→1 的贡献」，以及单独用「P 簇空闲、GPU 空闲」的秒（只有 E 簇在变）算的相关系数。
用法：m2_ecluster_recheck.py a.csv [b.csv ...]
"""
import csv, sys, math
import numpy as np
cols = None; X = []; Y = {}
for fn in sys.argv[1:]:
    rows = list(csv.reader(open(fn))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}
    keys = [k for k in h if len(k) == 4 and k[0] in 'TPVI']
    for r in rows[1:]:
        try: x = [float(r[ix[c]]) for c in ('util_c0', 'util_c1', 'util_c2', 'EM:GPU Energy')]
        except: continue
        if any(math.isnan(v) for v in x): continue
        X.append(x)
        for k in keys:
            try: v = float(r[ix[k]])
            except: v = float('nan')
            Y.setdefault(k, []).append(v)
X = np.array(X); N = len(X)
Y = {k: np.array(v) for k, v in Y.items() if len(v) == N and not np.isnan(v).any() and np.ptp(v) > 0}
A = np.column_stack([np.ones(N), X])
# 只有 E 簇在变的秒
mask = (X[:, 1] < 0.03) & (X[:, 2] < 0.03) & (X[:, 3] < 1.0)
print(f"N={N}；P 簇与 GPU 都空闲的秒={mask.sum()}，其中 util_c0 范围 {X[mask,0].min():.2f}–{X[mask,0].max():.2f}，标准差 {X[mask,0].std():.3f}")
out = []
for k, y in Y.items():
    beta, res, rk, sv = np.linalg.lstsq(A, y, rcond=None)
    r = y - A @ beta; s2 = (r @ r) / (N - A.shape[1]); cov = s2 * np.linalg.inv(A.T @ A); t0 = beta[1] / math.sqrt(cov[1, 1])
    ym = y[mask]; xm = X[mask, 0]
    rho = np.corrcoef(xm, ym)[0, 1] if ym.std() > 0 else 0
    out.append((abs(t0), k, beta[1], t0, beta[2], beta[3], beta[4], rho))
out.sort(reverse=True)
print("按 E 簇系数 |t| 排序前 30（β_E = util_c0 从 0→1 的变化量；ρ_E = 只有 E 簇变化时的相关系数）：")
for _, k, bE, tE, b1, b2, bg, rho in out[:30]:
    print(f"  {k}: β_E={bE:+.3f} (t={tE:+.1f})  β_P1={b1:+.3f} β_P2={b2:+.3f} β_GPU/W={bg:+.4f}  ρ_E={rho:+.2f}")
