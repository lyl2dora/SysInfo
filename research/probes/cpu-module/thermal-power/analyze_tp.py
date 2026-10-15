#!/usr/bin/env python3
"""analyze_tp.py — 分析 tp_watch 的 CSV：每个负载阶段相对前一个 idle 阶段的温度升幅、功耗键增量、Energy Model 增量。
用法：analyze_tp.py load.csv [--top N] [--keys PREFIXES]
输出：
  1) 每阶段的簇占用均值与热压力；
  2) 每阶段 T* 键升幅排名（阶段末 5 s 均值 − 前一 idle 阶段末 5 s 均值）；
  3) 每阶段 P*/R*/I*/V* 键增量（|Δ| 超阈值者）以及 Energy Model 通道均值；
  4) 键 → 簇 归属：以各阶段「簇占用增量」为自变量，对每个 T 键升幅做非负最小二乘，给出主导簇与拟合 R²。
"""
import csv, sys, math, argparse
from collections import OrderedDict

ap = argparse.ArgumentParser(); ap.add_argument('csv'); ap.add_argument('--top', type=int, default=40); ap.add_argument('--tail', type=int, default=5)
ap.add_argument('--minrise', type=float, default=1.0)
a = ap.parse_args()
rows = list(csv.reader(open(a.csv)))
hdr = rows[0]; data = rows[1:]
idx = {h: i for i, h in enumerate(hdr)}
ucols = [h for h in hdr if h.startswith('util_c')]
emcols = [h for h in hdr if h.startswith('EM:')]
first_key = hdr.index(emcols[-1]) + 1 if emcols else hdr.index('em_changed') + 1
keycols = hdr[first_key:]
def f(x):
    try: v = float(x); return v if not math.isnan(v) else None
    except: return None
# 切分阶段
phases = []
for r in data:
    if not phases or phases[-1]['name'] != r[1]: phases.append({'name': r[1], 'rows': []})
    phases[-1]['rows'].append(r)
def tailmean(ph, col, n=a.tail):
    vals = [f(r[idx[col]]) for r in ph['rows'][-n:]]; vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None
def mean(ph, col, skip=2):
    vals = [f(r[idx[col]]) for r in ph['rows'][skip:]]; vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None

results = []
for i, ph in enumerate(phases):
    if ph['name'] == 'idle' or i == 0: continue
    base = phases[i - 1]
    du = [ (mean(ph, u) or 0) - (tailmean(base, u) or 0) for u in ucols ]
    rises = {}
    for k in keycols:
        b, l = tailmean(base, k), tailmean(ph, k)
        if b is None or l is None: continue
        rises[k] = l - b
    results.append((ph, base, du, rises))
    print(f"\n=== phase {i} {ph['name']} ({len(ph['rows'])} s)  util: " + ' '.join(f"{u}={mean(ph,u):.2f}(Δ{d:+.2f})" for u, d in zip(ucols, du))
          + f"  thermpress(max)={max(int(r[idx['thermpress']]) for r in ph['rows'])}  em_changed(mean)={mean(ph,'em_changed',0):.1f}")
    em = ' '.join(f"{c[3:]}={mean(ph,c):.2f}" for c in emcols if mean(ph, c) is not None and abs(mean(ph, c)) > 0.001)
    print('  Energy Model W (mean, skip 2 s):', em or '(全部为 0 / NaN)')
    t = sorted([(v, k) for k, v in rises.items() if k.startswith('T')], reverse=True)
    print(f'  T* rise top {a.top}:', ' '.join(f"{k}:{v:+.1f}({tailmean(ph,k):.1f})" for v, k in t[:a.top]))
    p = sorted([(abs(v), v, k) for k, v in rises.items() if k[0] in 'PR' and abs(v) > 0.2], reverse=True)
    print('  P*/R* |Δ|>0.2 W:', ' '.join(f"{k}:{v:+.2f}({tailmean(ph,k):.2f})" for _, v, k in p[:50]))

# 键 → 簇 归属（非负最小二乘，逐键；只看在任一阶段升幅 ≥ minrise 的 T 键）
print('\n=== T 键 → 簇 归属（各阶段升幅 ~ Σ w_c·Δutil_c，w ≥ 0；dom=最大贡献簇）')
import itertools
def nnls(X, y):
    # 小维度穷举有效集
    n = len(X[0]); best = (float('inf'), [0]*n)
    for mask in range(1, 1 << n):
        cols = [j for j in range(n) if mask >> j & 1]
        # 正规方程
        A = [[sum(X[r][i]*X[r][j] for r in range(len(X))) for j in cols] for i in cols]
        b = [sum(X[r][i]*y[r] for r in range(len(X))) for i in cols]
        try: w = solve(A, b)
        except ZeroDivisionError: continue
        if any(v < 0 for v in w): continue
        full = [0]*n
        for c, v in zip(cols, w): full[c] = v
        res = sum((y[r] - sum(full[j]*X[r][j] for j in range(n)))**2 for r in range(len(X)))
        if res < best[0]: best = (res, full)
    return best
def solve(A, b):
    n = len(A); M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-9: raise ZeroDivisionError
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                fct = M[r][c] / M[c][c]; M[r] = [x - fct*y for x, y in zip(M[r], M[c])]
    return [M[i][n] / M[i][i] for i in range(n)]
X = [du for (_, _, du, _) in results]
tk = [k for k in keycols if k.startswith('T') and any(abs(r[3].get(k, 0)) >= a.minrise for r in results)]
rows_out = []
for k in tk:
    y = [r[3].get(k, 0) for r in results]
    res, w = nnls(X, y)
    ss = sum((v - sum(y)/len(y))**2 for v in y)
    r2 = 1 - res/ss if ss > 0 else 0
    contrib = [w[j]*max(abs(X[r][j]) for r in range(len(X))) for j in range(len(w))]
    dom = max(range(len(w)), key=lambda j: contrib[j]); share = contrib[dom]/sum(contrib) if sum(contrib) > 0 else 0
    rows_out.append((ucols[dom], -share, k, w, r2, y))
rows_out.sort()
for dom, nshare, k, w, r2, y in rows_out:
    print(f"  {k}: dom={dom} share={-nshare:.2f} R2={r2:.2f} w=[{', '.join(f'{v:.1f}' for v in w)}] rises=[{', '.join(f'{v:+.1f}' for v in y)}]")
