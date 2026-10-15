#!/usr/bin/env python3
"""m4_sentinel.py — M4 Pro 温度键的占位值与三元组检查（2026-10-15）。
- 占位值：簇或 GPU 断电时，键读出恰好 40.0 / -4.0 / 0.0。统计每个键在三份记录里出现这几个精确值的样本比例。
- 三元组：相邻三个键 (x0, x1, x2) 中，x1 − x0 在非占位样本上是否恒定（标准差 < 0.01），x2 是否 ≥ x1。
- 聚合键：Tpx* 等是否逐样本等于某组键的最大值。
用法：m4_sentinel.py <目录>"""
import csv, sys, statistics as st
from collections import defaultdict
d = sys.argv[1] if len(sys.argv) > 1 else 'm4out'
S = (40.0, -4.0, 0.0)
data = defaultdict(list)
for f in ('etoggle_m4', 'ptoggle_m4', 'gpu_m4'):
    R = list(csv.reader(open(f'{d}/{f}.csv'))); h = R[0]
    for r in R[1:]:
        for k, v in zip(h[2:], r[2:]):
            if k[0] == 'T': data[k].append(float(v))
sent = {k: {s: sum(1 for x in v if x == s) / len(v) for s in S} for k, v in data.items()}
withs = {k: v for k, v in sent.items() if max(v.values()) > 0.02}
print(f'温度键 {len(data)} 个，出现占位值（任一精确值占比 > 2%）的 {len(withs)} 个：')
fam = defaultdict(list)
for k, v in sorted(withs.items()):
    s = max(v, key=v.get); fam[(k[:2], s)].append(f'{k}({v[s]*100:.0f}%)')
for (p, s), ks in sorted(fam.items()): print(f'  {p}* 占位 {s:+.1f}: {len(ks)} 个  ' + ' '.join(ks[:14]) + (' …' if len(ks) > 14 else ''))
print('\n恒定偏移的键对（非占位样本上 x_b − x_a 标准差 < 0.01、样本 ≥ 30）：')
ks = sorted(data); pairs = []
for i, a in enumerate(ks):
    for b in ks[i+1:i+3]:
        if a[:3] != b[:3]: continue
        dd = [y - x for x, y in zip(data[a], data[b]) if x not in S and y not in S]
        if len(dd) >= 30 and st.pstdev(dd) < 0.01 and abs(st.mean(dd)) > 0.01: pairs.append((a, b, st.mean(dd)))
for a, b, m in pairs: print(f'  {b} = {a} {m:+.3f}')
print('\n聚合键（逐样本等于一组键的最大值，误差 < 0.01，非占位样本 ≥ 30）：')
for agg in [k for k in ks if 'x' in k[2:]]:
    others = [k for k in ks if k[:2] == agg[:2] and k != agg and 'x' not in k[2:]]
    good = [j for j, v in enumerate(data[agg]) if v not in S]
    if len(good) < 30: continue
    # 贪心：找出与 agg 相等次数最多的成员集合
    hit = [k for k in others if sum(1 for j in good if abs(data[k][j] - data[agg][j]) < 0.01) >= 3]
    if hit:
        ok = sum(1 for j in good if abs(max(data[k][j] for k in hit) - data[agg][j]) < 0.01) / len(good)
        print(f'  {agg}: 与 {len(hit)} 个键的最大值吻合 {ok*100:.0f}%  成员 {" ".join(hit[:12])}{" …" if len(hit) > 12 else ""}')
