#!/usr/bin/env python3
"""attrib_ratio.py — 每个温度键在 dfN 阶段的温升（阶段末 2 s − 阶段前 2 s），并给出「M1 响应比」= Δ(df18) / Δ(df12)：
M 簇 0 的键在 df12 已大幅升温，df18 只再加少许 → 比值接近 1；M 簇 1 的键在 df12 只有串扰 → 比值 ≫ 1。
另检验 TPDX/TRDX 是否逐样本等于 TPD*/TRD* 族最大值。
用法：attrib_ratio.py rec.csv"""
import csv, sys, statistics as st
rows = list(csv.reader(open(sys.argv[1]))); h = rows[0]; R = rows[1:]; ix = {k: i for i, k in enumerate(h)}
segs = []
for i, r in enumerate(R):
    if not segs or segs[-1][0] != r[1]: segs.append([r[1], i, i])
    segs[-1][2] = i
w = 4
def d(i, a, b): return st.mean(float(R[j][i]) for j in range(b - w + 1, b + 1)) - st.mean(float(R[j][i]) for j in range(a - w, a))
ld = [s for s in segs if s[0] != 'idle']
print('各阶段：', [(s[0], round(st.mean(float(R[j][ix['util_c0']]) for j in range(s[1], s[2]+1)), 2), round(st.mean(float(R[j][ix['util_c1']]) for j in range(s[1], s[2]+1)), 2)) for s in ld])
res = []
for k in h[2:]:
    if k[:2] not in ('Tm', 'Tp'): continue
    i = ix[k]; ds = {}
    for n, a, b in ld: ds.setdefault(n, []).append(d(i, a, b))
    d12 = st.mean(ds.get('df12', [0])); d18 = st.mean(ds.get('df18', [0]))
    res.append((k, d12, d18, d18 / d12 if d12 > 0.3 else float('inf')))
for k, d12, d18, rt in res:
    tag = 'M0 型' if rt < 1.6 else ('M1 型' if rt > 2.0 else '中间')
    if d18 < 1.0: tag = '无响应'
    print(f"  {k}: Δdf12={d12:+6.2f}  Δdf18={d18:+6.2f}  比={rt:5.2f}  {tag}")
for grp, mx in (('TPD', 'TPDX'), ('TRD', 'TRDX')):
    if mx not in ix: continue
    mem = [k for k in h if k.startswith(grp) and k != mx]
    eq = sum(1 for r in R if abs(float(r[ix[mx]]) - max(float(r[ix[k]]) for k in mem)) < 1e-3)
    print(f"{mx} == max({len(mem)} 个 {grp}*)：{eq}/{len(R)} 个样本")
    dd = [(k, d(ix[k], ld[0][1], ld[0][2])) for k in mem + [mx]]
    print(f"  {grp} 族 df12 首段温升：" + ' '.join(f"{k}={v:+.1f}" for k, v in dd))
