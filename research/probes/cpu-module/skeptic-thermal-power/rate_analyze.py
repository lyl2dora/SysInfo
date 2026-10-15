#!/usr/bin/env python3
"""rate_analyze.py — 从 sk_rec 的高频记录里估计每个键的更新周期：相邻「值发生变化」的时间间隔中位数/最小值，以及总变化次数。
用法：rate_analyze.py rec.csv"""
import csv, sys, statistics as st
rows = list(csv.reader(open(sys.argv[1]))); h = rows[0]; R = rows[1:]
t = [float(r[0]) for r in R]
print(f"样本 {len(R)}，时长 {t[-1]-t[0]:.1f} s，平均间隔 {(t[-1]-t[0])/(len(R)-1)*1e3:.0f} ms")
for i, k in enumerate(h):
    if i < 2 or k.startswith('util'): continue
    v = [r[i] for r in R]; ch = [t[j] for j in range(1, len(v)) if v[j] != v[j-1]]
    if len(ch) < 2: print(f"  {k}: 变化 {len(ch)} 次"); continue
    d = [b - a for a, b in zip(ch, ch[1:])]
    print(f"  {k}: 变化 {len(ch)} 次，间隔中位 {st.median(d)*1e3:.0f} ms，最小 {min(d)*1e3:.0f} ms，p90 {sorted(d)[int(.9*len(d))]*1e3:.0f} ms")
