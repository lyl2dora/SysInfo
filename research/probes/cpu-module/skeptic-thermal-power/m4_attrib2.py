#!/usr/bin/env python3
"""m4_attrib2.py — M4 Pro 温度键归簇（2026-10-15，取代 m4_attrib.py：两个 P 簇功率高度共线，加上整体缓慢升温，回归是病态的）。
- P0/P1：ptoggle 的 ui5 段里，5 个线程整体每约 2 s 在两个 P 簇之间切换一次（实测），形成方波 s = util_P0 − util_P1。
  对每个键做高通（减去 8 个样本、即 4 s 的居中滑动平均），在 0–4 个样本的滞后里找与 s 的最大相关；
  beta = 每整簇切换的温度摆幅（°C），正值 → P0，负值 → P1。
- E：etoggle 中 ui14 段末 3 s − 相邻 ui10 段末 3 s 的均值（P 簇全程满载，抵消漂移的方法同 e_toggle_analyze.py）。
- GPU：gpu 记录中负载末 6 s − 负载前 5 s；CPU 全程空闲。
- Pfull：ptoggle 中第一个 ui10 段末 3 s − 开头 idle 段末 3 s（两个 P 簇满载的总温升，作量级参考）。
用法：m4_attrib2.py <目录>"""
import csv, sys, statistics as st
d = sys.argv[1] if len(sys.argv) > 1 else 'm4out'
def load(f):
    R = list(csv.reader(open(f'{d}/{f}.csv'))); h = R[0]; R = R[1:]; return h, R, {k: i for i, k in enumerate(h)}
def segs_of(R):
    s = []
    for i, r in enumerate(R):
        if not s or s[-1][0] != r[1]: s.append([r[1], i, i])
        s[-1][2] = i
    return s
E = load('etoggle_m4'); P = load('ptoggle_m4'); G = load('gpu_m4')
keys = [k for k in E[0] if k[0] == 'T' and k in P[2] and k in G[2]]
def endm(X, k, s, w=6): h, R, ix = X; return st.mean(float(R[j][ix[k]]) for j in range(s[2] - w + 1, s[2] + 1))
# P 方波
h, R, ix = P; ps = segs_of(R); ui5 = [s for s in ps if s[0] == 'ui5']
def hp(v, w=8):
    o = []
    for i in range(len(v)):
        a = max(0, i - w // 2); b = min(len(v), i + w // 2 + 1); o.append(v[i] - st.mean(v[a:b]))
    return o
def psig(k):
    best = None
    for lag in range(0, 5):
        xs = []; ys = []
        for s in ui5:
            idx = list(range(s[1], s[2] + 1)); sw = [float(R[j][ix['util_c1']]) - float(R[j][ix['util_c2']]) for j in idx]
            t = hp([float(R[j][ix[k]]) for j in idx]); sw = hp(sw)
            for i in range(lag + 4, len(idx) - 4): xs.append(sw[i - lag]); ys.append(t[i])
        if st.pstdev(ys) < 1e-6: continue
        c = st.correlation(xs, ys); beta = st.covariance(xs, ys) / st.variance(xs)
        if best is None or abs(c) > abs(best[0]): best = (c, beta, lag)
    return best or (0.0, 0.0, 0)
# E
es = segs_of(E[1])
def edelta(k):
    ds = [endm(E, k, s) - (endm(E, k, es[i-1]) + endm(E, k, es[i+1])) / 2 for i, s in enumerate(es) if s[0] == 'ui14' and 0 < i < len(es) - 1]
    return st.mean(ds)
# GPU
gh, gR, gix = G; t0 = float(gR[0][0])
def gwin(k, a, b): return st.mean(float(r[gix[k]]) for r in gR if a <= float(r[0]) - t0 < b)
def gdelta(k): return gwin(k, 32, 38) - gwin(k, 2, 7)
pidle = ps[0]; pfull = next(s for s in ps if s[0] == 'ui10')
print('key    Pcorr  Pbeta lag |  dE(°C)  dGPU  dPfull | 判定')
rows = []
for k in keys:
    c, b, lag = psig(k); de = edelta(k); dg = gdelta(k); dp = endm(P, k, pfull) - endm(P, k, pidle)
    if abs(c) >= 0.6 and abs(b) >= 0.4: v = 'P0' if b > 0 else 'P1'
    elif de >= 1.5 and de >= 0.5 * max(dp, 0): v = 'E'
    elif dp < 1.0 and dg < 1.0 and de < 0.5: v = '-'
    else: v = 'shared'
    if v in ('P0', 'P1') and dg > 0.65 * dp: v += '?gpu'
    rows.append((k, c, b, lag, de, dg, dp, v))
for r in sorted(rows): print(f'{r[0]}  {r[1]:+.2f} {r[2]:+6.2f} {r[3]:3d} | {r[4]:+6.2f} {r[5]:+6.2f} {r[6]:+6.2f} | {r[7]}')
from collections import Counter
print('汇总：', dict(Counter(r[7] for r in rows)))
