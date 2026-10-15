#!/usr/bin/env python3
"""gpu_ratio_filter.py — 演示「把 GPU 功率作为回归自变量」后能否把 SoC 热点键（TCMb/TVD0 等）与 CPU 簇键分开。
自变量：各簇占用 + GPU 功率（M5 离线用 RP05+RP08 代替 AGX GPU Energy；M2 用 EM:GPU Energy），τ 秒一阶平滑 + 1 s 滞后，每文件去均值后拼接，最小二乘。
指标：g = GPU 贡献（β_G × GPU 功率范围） / 最大单簇贡献（β_c × 1.0）。CPU 簇键 g 小，SoC 热点 g 大。
用法：gpu_ratio_filter.py --gpu RP05+RP08|EM:GPU\\ Energy a.csv b.csv ..."""
import csv, sys, math, argparse
import numpy as np
ap = argparse.ArgumentParser(); ap.add_argument('csv', nargs='+'); ap.add_argument('--gpu', default='RP05+RP08'); ap.add_argument('--tau', type=float, default=3.0); a = ap.parse_args()
def sm(x):
    al = 1 - math.exp(-1 / a.tau); s = np.empty_like(x); acc = x[0]
    for i, v in enumerate(x): acc += al * (v - acc); s[i] = acc
    return np.concatenate([[s[0]], s[:-1]])
Xs = []; Ys = {}; ucols = None; grng = 0
for fn in a.csv:
    rows = list(csv.reader(open(fn))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}; R = rows[1:]
    col = lambda k: np.array([float(r[ix[k]]) for r in R])
    uc = [c for c in h if c.startswith('util_c')]; ucols = uc
    g = sum((col(k) if k in ix else np.zeros(len(R))) for k in a.gpu.split("+")); grng = max(grng, np.ptp(g))  # 文件里没有 GPU 列 = 该段 GPU 空闲
    X = np.column_stack([sm(col(c)) for c in uc] + [sm(g)]); X -= X.mean(0); Xs.append(X)
    for k in h:
        if len(k) == 4 and k[0] == 'T': y = col(k); Ys.setdefault(k, []).append(y - y.mean())
X = np.vstack(Xs); Y = {k: np.concatenate(v) for k, v in Ys.items() if len(v) == len(a.csv)}
rows = []
for k, y in Y.items():
    if np.ptp(y) < 0.5: continue
    b, *_ = np.linalg.lstsq(X, y, rcond=None); r2 = 1 - ((y - X @ b) ** 2).mean() / y.var()
    cc = b[:-1]; gc = b[-1] * grng; dom = int(np.argmax(cc)); ratio = gc / max(cc[dom], 1e-3)
    rows.append((ratio, k, ucols[dom], cc[dom], gc, r2))
rows.sort()
print(f"GPU 功率范围 {grng:.1f} W；g = GPU 贡献 / 最大单簇贡献")
for ratio, k, d, c, gc, r2 in rows:
    if k.startswith(('TCMb', 'TVD', 'TPD', 'TCMz', 'Tf0', 'Tg', 'Te0')) or k in ('Tp00', 'Tp0a', 'Tm00', 'Tm1M', 'Tm29', 'Tp01', 'Tp1J', 'Tp0A', 'Tp1C') or ratio > 0.45:
        print(f"  {k:5s} 主簇={d} 簇贡献={c:+6.1f} GPU贡献={gc:+6.1f} g={ratio:5.2f} R2={r2:.2f}")
print('全部键 g 的分布：', ' '.join(f"{q}%={np.percentile([r[0] for r in rows], q):.2f}" for q in (10, 50, 90)))
