#!/usr/bin/env python3
"""rail_discover_sim.py — 离线模拟「不写死键名」的 CPU 功耗轨发现：
对每个 P*/R* 功率键（W），以各簇占用 util_c* 与 AGX 实时 GPU 功率（EM:GPU Energy，W）为自变量做非负最小二乘（无平滑、无滞后），
按贡献（β×自变量范围）分类：
  - 簇专用 CPU 轨：GPU 贡献 < 10%，且单一簇贡献占 CPU 部分 ≥ 80%；
  - 共享 CPU 轨：GPU 贡献 < 10%，多簇共同贡献；
  - 含 GPU 的轨（SoC / 整机 / 共享 VR）：GPU 贡献 ≥ 10%；
  - 其余（R² < 0.6 或总贡献 < 0.5 W）忽略。
用法：rail_discover_sim.py a.csv [b.csv ...]
"""
import csv, math, sys
files = sys.argv[1:]
Xs = None; Y = {}; names = None
for fn in files:
    rows = list(csv.reader(open(fn))); h = rows[0]; R = rows[1:]
    uc = [c for c in h if c.startswith('util_c')] + ['EM:GPU Energy']
    if names is None: names = uc; Xs = [[] for _ in uc]
    for j, c in enumerate(uc):
        v = [float(r[h.index(c)]) for r in R]; m = sum(v) / len(v); Xs[j] += [x - m for x in v]
    for i, k in enumerate(h):
        if not (len(k) == 4 and k[0] in 'PR' and k != 'phase'): continue
        try: v = [float(r[i]) for r in R]
        except: continue
        if any(math.isnan(x) for x in v): continue
        m = sum(v) / len(v); Y.setdefault(k, []).append([x - m for x in v])
Y = {k: [x for part in v for x in part] for k, v in Y.items() if len(v) == len(files)}
N = len(Xs[0]); rng = [max(x) - min(x) for x in Xs]
def solve(A, b):
    n = len(A); M = [A[i][:] + [b[i]] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-12: return None
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]; M[r] = [u - f * w for u, w in zip(M[r], M[c])]
    return [M[i][n] / M[i][i] for i in range(n)]
G = [[sum(Xs[i][t] * Xs[j][t] for t in range(N)) for j in range(len(Xs))] for i in range(len(Xs))]
def nnls(y):
    b = [sum(Xs[i][t] * y[t] for t in range(N)) for i in range(len(Xs))]; best = (float('inf'), [0.0] * len(Xs))
    for mask in range(1, 1 << len(Xs)):
        cols = [j for j in range(len(Xs)) if mask >> j & 1]
        w = solve([[G[i][j] for j in cols] for i in cols], [b[i] for i in cols])
        if w is None or any(v < 0 for v in w): continue
        full = [0.0] * len(Xs)
        for c, v in zip(cols, w): full[c] = v
        res = sum((y[t] - sum(full[j] * Xs[j][t] for j in range(len(Xs)))) ** 2 for t in range(N))
        if res < best[0]: best = (res, full)
    return best
print(f"N={N}；自变量={names}（最后一项为 AGX 实时 GPU 功率）")
out = []
for k, y in Y.items():
    ss = sum(v * v for v in y)
    if ss == 0: continue
    res, w = nnls(y); r2 = 1 - res / ss; con = [w[j] * rng[j] for j in range(len(w))]; tot = sum(con)
    if r2 < 0.6 or tot < 0.5: continue
    gpu = con[-1] / tot; cpu = con[:-1]; cs = sum(cpu)
    dom = max(range(len(cpu)), key=lambda j: cpu[j]); share = cpu[dom] / cs if cs > 0 else 0
    if gpu >= 0.10: lab = '含 GPU 的轨'
    elif share >= 0.8: lab = f'簇专用 CPU 轨 → {names[dom]}'
    else: lab = '共享 CPU 轨'
    out.append((lab, -tot, k, r2, con))
out.sort()
for lab, nt, k, r2, con in out:
    print(f"  {k}: {lab:22s} R2={r2:.2f} 贡献(W)=[{', '.join(f'{c:.1f}' for c in con)}]")
