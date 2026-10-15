#!/usr/bin/env python3
"""phase_delta.py — 每个负载阶段：键值「阶段最后 2 s 均值 − 阶段开始前 2 s 均值」，按键族分组汇总（均值/最大）。
用法：phase_delta.py rec.csv"""
import csv, sys, statistics as st, re
rows = list(csv.reader(open(sys.argv[1]))); h = rows[0]; R = rows[1:]
hz = round((len(R) - 1) / (float(R[-1][0]) - float(R[0][0])))
segs = []
for i, r in enumerate(R):
    if not segs or segs[-1][0] != r[1]: segs.append([r[1], i, i])
    segs[-1][2] = i
w = 2 * hz
fam = {}
for i, k in enumerate(h[2:], 2):
    f = 'Tp0(Super)' if k.startswith('Tp0') else 'Tm0(M0)' if k.startswith('Tm0') else 'Tm1' if k.startswith('Tm1') else 'Tm2' if k.startswith('Tm2') else k
    if k in ('Tm0y', 'Tm2T'): f = 'Tm0y/Tm2T(别名)'
    fam.setdefault(f, []).append(i)
print('阶段'.ljust(8) + ''.join(f"{f:>18s}" for f in fam))
for name, a, b in segs:
    if name == 'idle' or a < w: continue
    line = f"{name:8s}"
    for f, idx in fam.items():
        ds = []
        for i in idx:
            pre = st.mean(float(R[j][i]) for j in range(a - w, a)); end = st.mean(float(R[j][i]) for j in range(b - w + 1, b + 1))
            ds.append(end - pre)
        line += f"{st.mean(ds):+8.2f}/{max(ds):+7.2f}  " if len(ds) > 1 else f"{ds[0]:+17.2f} "
    print(line)
print('（Tp/Tm 族显示 族均值/族最大；其余为单键 Δ）')
for f, idx in fam.items():
    if len(idx) > 1: print(f, len(idx), '键:', ' '.join(h[i] for i in idx))
