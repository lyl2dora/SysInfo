#!/usr/bin/env python3
"""m4_attrib.py — M4 Pro 温度键归簇（2026-10-15）。三份记录：etoggle（ui10↔ui14，翻转 E 簇）、ptoggle（ui5↔ui10，ui5 时线程在两个 P 簇间迁移）、gpu（30 s Metal 负载）。
自变量用功耗轨（先在本机实测确认：RP05+RP06 = P 簇 0（cluster-id 1），RP00+RP01 = P 簇 1（cluster-id 2），RP02 = E 簇，RP07+RP0b = GPU），
按每瓦敏感度判定（讨论稿 §7.3）。温度对功率有热滞后，自变量先做一阶指数平滑（tau 取 R² 最好的一档）。
对每个键拟合 T = c + bP0·x_P0 + bP1·x_P1 + bE·x_E + bG·x_G（三份记录各自带截距），输出 °C/W。
用法：m4_attrib.py <目录>"""
import csv, sys, math
d = sys.argv[1] if len(sys.argv) > 1 else 'm4out'
RAILS = {'P0': ('RP05', 'RP06'), 'P1': ('RP00', 'RP01'), 'E': ('RP02',), 'G': ('RP07', 'RP0b')}
runs = []
for f in ('etoggle_m4', 'ptoggle_m4', 'gpu_m4'):
    R = list(csv.reader(open(f'{d}/{f}.csv'))); h = R[0]; R = R[1:]; ix = {k: i for i, k in enumerate(h)}
    runs.append((f, h, R, ix))
keys = [k for k in runs[0][1] if k[0] == 'T' and all(k in r[3] for r in runs)]
def ema(v, tau, dt=0.5):
    a = 1 - math.exp(-dt / tau); o = []; s = v[0]
    for x in v: s += a * (x - s); o.append(s)
    return o
def solve(A, b):
    n = len(b); M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c])); M[c], M[p] = M[p], M[c]
        if abs(M[c][c]) < 1e-12: return None
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]; M[r] = [x - f * y for x, y in zip(M[r], M[c])]
    return [M[i][n] / M[i][i] for i in range(n)]
def fit(k, tau):
    X = []; Y = []
    for ri, (f, h, R, ix) in enumerate(runs):
        xs = {g: ema([sum(float(r[ix[c]]) for c in cs) for r in R], tau) for g, cs in RAILS.items()}
        for j, r in enumerate(R):
            row = [1.0 if q == ri else 0.0 for q in range(len(runs))] + [xs[g][j] for g in RAILS]
            X.append(row); Y.append(float(r[ix[k]]))
    n = len(X[0]); A = [[sum(X[i][a] * X[i][b] for i in range(len(X))) for b in range(n)] for a in range(n)]
    bb = [sum(X[i][a] * Y[i] for i in range(len(X))) for a in range(n)]
    w = solve(A, bb)
    if w is None: return None
    pred = [sum(a * b for a, b in zip(x, w)) for x in X]; my = sum(Y) / len(Y)
    ss = sum((y - p) ** 2 for y, p in zip(Y, pred)); st = sum((y - my) ** 2 for y in Y)
    return (1 - ss / st if st > 0 else 0, w[len(runs):])
out = []
for k in keys:
    best = None
    for tau in (1, 2, 4, 8):
        r = fit(k, tau)
        if r and (best is None or r[0] > best[0]): best = (r[0], r[1], tau)
    if best: out.append((k, *best))
print('key   R2    tau  °C/W: P0     P1     E      GPU   | 判定')
for k, r2, (b0, b1, be, bg), tau in sorted(out):
    cpu = {'P0': b0, 'P1': b1, 'E': be}; top = max(cpu, key=cpu.get); second = sorted(cpu.values())[-2]
    # 判据：最大 CPU 簇敏感度 ≥ 2× 次大，且 GPU 敏感度 < 0.65× 该簇（讨论稿 §2.3 的相对判据）
    if r2 < 0.5 or cpu[top] < 0.05: verdict = '-'
    elif cpu[top] >= 2 * max(second, 1e-9) and bg < 0.65 * cpu[top]: verdict = top
    elif bg >= 0.65 * cpu[top]: verdict = 'SoC/GPU'
    else: verdict = 'shared'
    print(f'{k} {r2:5.2f} {tau:4d}  {b0:6.3f} {b1:6.3f} {be:6.3f} {bg:6.3f} | {verdict}')
