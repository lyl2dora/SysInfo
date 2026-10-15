#!/usr/bin/env python3
"""e_toggle_analyze.py — M2 E 簇激励测试分析：P 簇全程满载（ui8），E 簇在 ui12 段被拉满（高频），在 ui8 段回到背景。
对每个键，计算每个 ui12 段末 3 s 均值 − 前后相邻 ui8 段末 3 s 均值的平均（抵消 P 簇持续升温的漂移），并与 bg 段对比。
用法：e_toggle_analyze.py rec.csv [基线阶段名=ui8] [切换阶段名=ui12]"""
import csv, sys, statistics as st
rows = list(csv.reader(open(sys.argv[1]))); h = rows[0]; R = rows[1:]; ix = {k: i for i, k in enumerate(h)}
hz = round((len(R) - 1) / (float(R[-1][0]) - float(R[0][0])))
segs = []
for i, r in enumerate(R):
    if not segs or segs[-1][0] != r[1]: segs.append([r[1], i, i])
    segs[-1][2] = i
w = 3 * hz
BASE = sys.argv[2] if len(sys.argv) > 2 else "ui8"; TOG = sys.argv[3] if len(sys.argv) > 3 else "ui12"
def endm(k, s): return st.mean(float(R[j][ix[k]]) for j in range(s[2] - w + 1, s[2] + 1))
print('段：', [(s[0], round(st.mean(float(R[j][ix['util_c0']]) for j in range(s[1], s[2]+1)), 2)) for s in segs])
res = []
for k in h[2:]:
    ds = []
    for i, s in enumerate(segs):
        if s[0] == TOG and 0 < i < len(segs) - 1 and segs[i-1][0] == BASE and segs[i+1][0] == BASE:
            ds.append(endm(k, s) - (endm(k, segs[i-1]) + endm(k, segs[i+1])) / 2)
    if ds: res.append((st.mean(ds), k, ds))
res.sort(key=lambda x: -abs(x[0]))
print(f'切换段（{TOG} − 相邻 {BASE}）的平均变化，|Δ| 前 25：')
for m, k, ds in res[:25]: print(f"  {k}: {m:+.3f}  （各段 {', '.join(f'{d:+.2f}' for d in ds)}）")
