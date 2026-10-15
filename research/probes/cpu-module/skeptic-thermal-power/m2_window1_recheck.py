#!/usr/bin/env python3
"""m2_window1_recheck.py — 复核 thermal-power 对 M2 窗口 1 的 CPU 功耗估算（独立实现）。
窗口：CSV 开头 → 第一个 PMGR 批次（批次覆盖 1800 s，CSV 只覆盖其中一部分，故估算为下限）。
对多种基底 B ∈ {PSVR, PSVC, PHPC, PZC0, PZC1}：est = Σ max(0, B − GPU_AGX − c)·dt，c = 两个 P 簇占用都 < pidle 的秒里 (B − GPU) 的中位数。
另外输出：P 簇空闲秒的底噪分布、est 按「P 簇负载秒 / 空闲秒」拆分，以说明比值对 c 的敏感度。
用法：m2_window1_recheck.py passive_m2.csv
"""
import csv, sys, math, statistics as st
rows = list(csv.reader(open(sys.argv[1]))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}; R = rows[1:]
def f(r, k):
    try:
        v = float(r[ix[k]]); return 0.0 if math.isnan(v) else v
    except Exception: return 0.0
t = [float(r[0]) for r in R]; dt = [t[i] - t[i-1] if i else 1.0 for i in range(len(t))]
b = [i for i, r in enumerate(R) if f(r, 'EM:CPU Energy') > 100][0]
E = {k: f(R[b], 'EM:'+k)*dt[b] for k in ('CPU Energy','EACC_CPU','PACC0_CPU','PACC1_CPU','GPU0','DRAM0')}
pacc = E['PACC0_CPU'] + E['PACC1_CPU']
rng = range(0, b)   # 批次行之前的所有秒
span = sum(dt[i] for i in rng)
print(f"CSV 覆盖 {span:.0f} s（批次窗口 1800 s，缺 {1800-span:.0f} s）；PMGR: " + ', '.join(f"{k}={v:.0f} J" for k, v in E.items()))
agx = sum(f(R[i],'EM:GPU Energy')*dt[i] for i in rng)
print(f"AGX 实时 GPU 积分={agx:.0f} J；PMGR GPU0={E['GPU0']:.0f} J；按覆盖比例外推 AGX={agx*1800/span:.0f} J")
for pid in (0.02, 0.05, 0.10):
    idle = [i for i in rng if f(R[i],'util_c1') < pid and f(R[i],'util_c2') < pid]
    print(f"\n-- pidle={pid}: P 簇空闲秒 {len(idle)}/{len(rng)}")
    for key in ('PSVR','PSVC','PHPC','PZC0','PZC1'):
        d = [f(R[i],key)-f(R[i],'EM:GPU Energy') for i in idle]
        c = st.median(d); q1, q3 = st.quantiles(d, n=4)[0], st.quantiles(d, n=4)[2]
        est = sum(max(0.0, f(R[i],key)-f(R[i],'EM:GPU Energy')-c)*dt[i] for i in rng)
        busy = sum(max(0.0, f(R[i],key)-f(R[i],'EM:GPU Energy')-c)*dt[i] for i in rng if i not in set(idle))
        # c 变动 ±0.1 W 的敏感度
        est_lo = sum(max(0.0, f(R[i],key)-f(R[i],'EM:GPU Energy')-(c+0.1))*dt[i] for i in rng)
        est_hi = sum(max(0.0, f(R[i],key)-f(R[i],'EM:GPU Energy')-(c-0.1))*dt[i] for i in rng)
        print(f"  {key}: c={c:.2f} W (IQR {q1:.2f}–{q3:.2f})  est={est:.0f} J  /PACC={est/pacc:.3f}  /CPU={est/E['CPU Energy']:.3f}  非空闲秒贡献={busy:.0f} J  c±0.1W → /PACC {est_lo/pacc:.3f}–{est_hi/pacc:.3f}")
# 平均 P 簇占用、E 簇占用
u = {k: sum(f(R[i],k) for i in rng)/len(rng) for k in ('util_c0','util_c1','util_c2')}
print('\n平均占用', {k: round(v,3) for k, v in u.items()})
