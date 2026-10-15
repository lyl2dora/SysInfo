#!/usr/bin/env python3
"""discover_sim.py — 离线模拟「不写死键名」的 CPU 温度键发现逻辑，并用负载实验得出的归属做对照评估。
算法（拟在 app 里实现的版本，全部只依赖运行时数据）：
  1) 候选：首字母 T、可按数值解码、取值 10–125 °C、观察期内有变化（极差 ≥ 0.5 °C）的键；
  2) 别名合并：两键之差的标准差 < 0.05 °C（恒等或恒定偏移，如 M2 的 x0/x1 变体、M5 的 Tm0y=Tm2T=Tp0a）→ 同组，只保留一个代表；
  3) 回归：每簇占用（host_processor_info 按 cluster-id 汇总；1 s 滞后 + τ=1.5 s 一阶平滑模拟热惯性）为自变量，
     对每个代表键做非负最小二乘（β ≥ 0，避免多簇同时负载时的共线性给出正负抵消的系数）；
  4) 激励检查：簇 c 占用序列对其余簇做线性回归后的残差标准差（独立激励）< min_indep 的簇不接受归属（共线性太强，分不开）；
  5) 判定：先把每簇贡献按「全体键里对该簇响应最强者」归一化（消除簇间功耗量级差异）；R² ≥ r2、主导簇归一化响应 ≥ share、
     且比第二簇高 ≥ margin、贡献 ≥ minc °C、该簇独立激励足够 → 归该簇；R² ≥ r2 且 总贡献 ≥ minc 但无主导簇 → 「CPU 共享/SoC」；否则不是 CPU 温度键。
用法：discover_sim.py a.csv [b.csv ...] --truth m2|m5 [--share 0.7] [--r2 0.5] [--minc 3] [--min-indep 0.1]
"""
import csv, math, argparse, re
from itertools import combinations
ap = argparse.ArgumentParser(); ap.add_argument('csv', nargs='+'); ap.add_argument('--truth', default=None)
ap.add_argument('--share', type=float, default=0.6); ap.add_argument('--margin', type=float, default=0.25); ap.add_argument('--r2', type=float, default=0.5); ap.add_argument('--minc', type=float, default=3.0)
ap.add_argument('--min-indep', type=float, default=0.1); ap.add_argument('--tau', type=float, default=1.5); ap.add_argument('--lag', type=int, default=1)
a = ap.parse_args()

U = None; K = {}; ucols = None
for fn in a.csv:
    rows = list(csv.reader(open(fn))); h = rows[0]; n = len(rows) - 1
    uc = [c for c in h if c.startswith('util_c')]
    if ucols is None: ucols = uc; U = {c: [] for c in uc}
    alpha = 1 - math.exp(-1 / a.tau)
    for c in uc:
        raw = [float(r[h.index(c)]) for r in rows[1:]]; s = []; acc = raw[0]
        for v in raw: acc += alpha * (v - acc); s.append(acc)
        s = [s[0]] * a.lag + s[:n - a.lag]; U[c].append((raw, s))
    for i, k in enumerate(h):
        if not (len(k) == 4 and k[0] == 'T'): continue
        try: v = [float(r[i]) for r in rows[1:]]
        except: continue
        if any(math.isnan(x) for x in v): continue
        K.setdefault(k, []).append(v)
K = {k: vs for k, vs in K.items() if len(vs) == len(a.csv)}
# 1) 候选
cand = {}
for k, vs in K.items():
    allv = [x for v in vs for x in v]
    if min(allv) < 10 or max(allv) > 125: continue
    if max(allv) - min(allv) < 0.5: continue
    cand[k] = vs
# 每个文件分别去均值后拼接
def demean(v): m = sum(v) / len(v); return [x - m for x in v]
Y = {k: [x for v in vs for x in demean(v)] for k, vs in cand.items()}
X = [[x for (raw, s) in U[c] for x in demean(s)] for c in ucols]
RAW = [[x for (raw, s) in U[c] for x in raw] for c in ucols]
N = len(X[0])
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
# 2) 别名合并（全局比较差值标准差）
keys = sorted(Y); parent = {k: k for k in keys}
def find(k):
    while parent[k] != k: k = parent[k]
    return k
for i, j in combinations(range(len(keys)), 2):
    ki, kj = keys[i], keys[j]
    d = [p - q for p, q in zip(Y[ki], Y[kj])]; m = sum(d) / N
    if math.sqrt(sum((x - m) ** 2 for x in d) / N) < 0.05: parent[find(kj)] = find(ki)
groups = {}
for k in keys: groups.setdefault(find(k), []).append(k)
means = {k: sum(x for v in cand[k] for x in v) / N for k in keys}
reps = {max(g, key=lambda k: means[k]): g for g in groups.values()}   # 代表取组内均值最高者（x1 型）
# 4) 激励：簇占用中「不能被其它簇占用线性解释」的部分的标准差（共线性检查，类似 VIF）
def lstsq_cols(cols, y):
    A = [[sum(cols[i][t] * cols[j][t] for t in range(len(y))) for j in range(len(cols))] for i in range(len(cols))]
    b = [sum(cols[i][t] * y[t] for t in range(len(y))) for i in range(len(cols))]
    return solve(A, b) or [0.0] * len(cols)
solo = []
for ci in range(len(ucols)):
    others = [X[j] for j in range(len(ucols)) if j != ci]
    w = lstsq_cols(others, X[ci]); res = [X[ci][t] - sum(w[k] * others[k][t] for k in range(len(others))) for t in range(N)]
    solo.append(math.sqrt(sum(r * r for r in res) / N))
print(f"N={N} s；簇={ucols}；独立激励（残差标准差）={[round(x, 3) for x in solo]}；候选温度键={len(cand)}，别名合并后={len(reps)}")
excited = [s >= a.min_indep for s in solo]
# 3) NNLS（小维度：穷举有效集）
G = [[sum(X[i][t] * X[j][t] for t in range(N)) for j in range(len(X))] for i in range(len(X))]
urange = [max(r) - min(r) for r in RAW]
def nnls(y):
    b = [sum(X[i][t] * y[t] for t in range(N)) for i in range(len(X))]
    best = (float('inf'), [0.0] * len(X))
    for mask in range(1, 1 << len(X)):
        cols = [j for j in range(len(X)) if mask >> j & 1]
        w = solve([[G[i][j] for j in cols] for i in cols], [b[i] for i in cols])
        if w is None or any(v < 0 for v in w): continue
        full = [0.0] * len(X)
        for c, v in zip(cols, w): full[c] = v
        res = sum((y[t] - sum(full[j] * X[j][t] for j in range(len(X)))) ** 2 for t in range(N))
        if res < best[0]: best = (res, full)
    return best
result = {}
fits = {}
for rep, grp in reps.items():
    y = Y[rep]; res, w = nnls(y); ss = sum(v * v for v in y); r2 = 1 - res / ss if ss > 0 else 0
    fits[rep] = (r2, [w[j] * urange[j] for j in range(len(X))], grp)
# 归一化：每簇取「对该簇响应最强的键」的贡献为 1（消除各簇功耗量级差异，如 M5 的 M 簇远小于 Super 簇）
cmax = [max((f[1][j] for f in fits.values() if f[0] >= a.r2), default=0) or 1e-9 for j in range(len(X))]
for rep, (r2, contrib, grp) in fits.items():
    norm = [contrib[j] / cmax[j] for j in range(len(X))]
    order = sorted(range(len(X)), key=lambda j: -norm[j]); dom, sec = order[0], order[1]
    tot = sum(contrib)
    if r2 >= a.r2 and contrib[dom] >= a.minc and norm[dom] >= a.share and norm[dom] - norm[sec] >= a.margin and excited[dom]: label = ucols[dom]
    elif r2 >= a.r2 and tot >= a.minc: label = 'shared'
    else: label = '-'
    result[rep] = (label, r2, norm[dom], contrib, grp)
for lab in ucols + ['shared']:
    ks = sorted([k for k in result if result[k][0] == lab], key=lambda k: -sum(result[k][3]))
    print(f"\n[{lab}] {len(ks)} 组：")
    for k in ks:
        l, r2, sh, cb, grp = result[k]
        print(f"   {k}{'(=' + ','.join(g for g in grp if g != k) + ')' if len(grp) > 1 else ''}  R2={r2:.2f} norm={sh:.2f} contrib=[{', '.join(f'{c:.1f}' for c in cb)}]")
# 评估
truth = None
if a.truth == 'm2':
    truth = {'util_c1': re.compile(r'^Tp0[0-9A-Za-k]$'), 'util_c2': re.compile(r'^Tp1[A-Og-u]$')}
elif a.truth == 'm5':
    truth = {'util_c0': re.compile(r'^Tm0(?!y)'), 'util_c1': re.compile(r'^Tm[12](?!T)'), 'util_c2': re.compile(r'^(Tp0|Tm0y$|Tm2T$)')}
if truth:
    print('\n== 评估（对照负载实验得出的归属；按别名组计，组内任一成员匹配即算该簇）')
    for c, rx in truth.items():
        exp = {rep for rep, grp in reps.items() if any(rx.match(g) for g in grp)}
        got = {k for k in result if result[k][0] == c}
        wrong = {k for k in got if k not in exp}
        print(f"  {c}: 真值组={len(exp)} 判入={len(got)} 命中={len(exp & got)} 误判入={sorted(wrong)} 漏判={sorted(exp - got)[:12]}{'…' if len(exp - got) > 12 else ''}")
