#!/usr/bin/env python3
"""analyze_pulse.py — 对 tp_watch 的脉冲式负载 CSV 做「键 ↔ 簇」相关分析（抗背景噪声）。
对每个 SMC 键 k 与每个簇占用序列 U_c（先按 lag 秒右移，并做 τ 秒一阶平滑以近似热惯性）计算 Pearson r 与最小二乘斜率；
再对所有簇做多元回归 k ~ Σ β_c·U_c，给出主导簇（β_c·ΔU_c 贡献最大）与该簇贡献占比。
用法：analyze_pulse.py a.csv [b.csv ...] [--prefix T] [--lag 1] [--tau 2] [--minslope 1.0]
多个 CSV 会先各自去均值再拼接（同一台机器的多次运行）。
"""
import csv, sys, math, argparse
ap = argparse.ArgumentParser(); ap.add_argument('csv', nargs='+'); ap.add_argument('--prefix', default='T'); ap.add_argument('--lag', type=int, default=1)
ap.add_argument('--tau', type=float, default=2.0); ap.add_argument('--minslope', type=float, default=1.0); ap.add_argument('--show', type=int, default=400)
a = ap.parse_args()

def load(fn):
    rows = list(csv.reader(open(fn))); hdr = rows[0]
    cols = {h: [] for h in hdr}
    for r in rows[1:]:
        for h, v in zip(hdr, r):
            try: x = float(v)
            except: x = float('nan')
            cols[h].append(x if h != 'phase' else v)
    return hdr, cols
series = {}; ucols = None; hdr0 = None
for fn in a.csv:
    hdr, cols = load(fn)
    if hdr0 is None: hdr0 = hdr
    uc = [h for h in hdr if h.startswith('util_c')]; ucols = uc
    n = len(cols['t'])
    # 平滑 + 滞后的簇占用
    alpha = 1 - math.exp(-1 / a.tau) if a.tau > 0 else 1
    for h in uc:
        s = []; acc = cols[h][0]
        for v in cols[h]: acc += alpha * (v - acc); s.append(acc)
        s = [s[0]] * a.lag + s[:n - a.lag]
        m = sum(s) / n; series.setdefault(h, []).extend([v - m for v in s])
    for h in hdr:
        if h in ('t', 'phase') or h.startswith('util_c'): continue
        v = cols[h]
        good = [x for x in v if not math.isnan(x)]
        if len(good) < n * 0.9: continue
        m = sum(good) / len(good)
        series.setdefault(h, []).extend([(x - m) if not math.isnan(x) else 0 for x in v])
N = len(series[ucols[0]])
def pearson(x, y):
    sx = math.sqrt(sum(v*v for v in x)); sy = math.sqrt(sum(v*v for v in y))
    return sum(p*q for p, q in zip(x, y)) / (sx*sy) if sx > 0 and sy > 0 else 0
def lstsq(X, y):
    k = len(X); A = [[sum(X[i][t]*X[j][t] for t in range(N)) for j in range(k)] for i in range(k)]; b = [sum(X[i][t]*y[t] for t in range(N)) for i in range(k)]
    M = [A[i][:] + [b[i]] for i in range(k)]
    for c in range(k):
        p = max(range(c, k), key=lambda r: abs(M[r][c])); M[c], M[p] = M[p], M[c]
        if abs(M[c][c]) < 1e-12: return [0]*k
        for r in range(k):
            if r != c:
                f = M[r][c] / M[c][c]; M[r] = [u - f*w for u, w in zip(M[r], M[c])]
    return [M[i][k] / M[i][i] for i in range(k)]
X = [series[u] for u in ucols]
urange = [max(x) - min(x) for x in X]
out = []
for h, y in series.items():
    if h.startswith('util_c') or not h.startswith(tuple(a.prefix.split(','))): continue
    if len(y) != N: continue
    beta = lstsq(X, y)
    pred = [sum(beta[i]*X[i][t] for i in range(len(X))) for t in range(N)]
    ss = sum(v*v for v in y); res = sum((y[t]-pred[t])**2 for t in range(N)); r2 = 1 - res/ss if ss > 0 else 0
    contrib = [beta[i]*urange[i] for i in range(len(X))]
    pos = [max(0, c) for c in contrib]
    dom = max(range(len(X)), key=lambda i: contrib[i])
    share = pos[dom] / sum(pos) if sum(pos) > 0 else 0
    rs = [pearson(X[i], y) for i in range(len(X))]
    if max(abs(c) for c in contrib) < a.minslope: continue
    out.append((ucols[dom], -contrib[dom], h, beta, r2, share, rs))
out.sort()
print(f"N={N} samples, clusters={ucols}, lag={a.lag}s tau={a.tau}s; contrib = β·(占用范围)，单位同键值（°C 或 W）")
for dom, nc, h, beta, r2, share, rs in out[:a.show]:
    print(f"  {h:5s} dom={dom} contrib={-nc:+6.2f} share={share:.2f} R2={r2:.2f} beta=[{', '.join(f'{b:+6.2f}' for b in beta)}] r=[{', '.join(f'{r:+.2f}' for r in rs)}]")
