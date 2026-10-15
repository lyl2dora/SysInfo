#!/usr/bin/env python3
"""m2_window_recheck.py — 在 PMGR 批次窗口内检验 M2 实时 CPU 功耗估算（独立实现，适用于完整窗口）。
批次 = EM:CPU Energy 列 > 100 J 的行（相邻 3 行内合并）；相邻两个批次之间为完整窗口；CSV 开头到第一个批次为不完整窗口（下限）。
P 簇：est = Σ max(0, B − GPU_AGX − c)·dt，B ∈ {PSVR, PSVC, PZC0, PZC1, PHPC}，c = P 簇空闲秒中位数；对比 PACC0+PACC1。
E 簇：est = Σ max(0, PPSR − k·GPU − c)·dt，k=0 或 0.034（M2 GPU 泄漏系数，脉冲数据回归所得），c = E 低占用且 P 空闲秒中位数；对比 EACC_CPU。
用法：m2_window_recheck.py watch.csv [--pidle 0.02]
"""
import csv, sys, math, statistics as st, argparse, time
ap = argparse.ArgumentParser(); ap.add_argument('csv'); ap.add_argument('--pidle', type=float, default=0.02); a = ap.parse_args()
rows = list(csv.reader(open(a.csv))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}; R = rows[1:]
def f(r, k):
    try:
        v = float(r[ix[k]]); return 0.0 if math.isnan(v) else v
    except Exception: return 0.0
t = [float(r[0]) for r in R]; dt = [t[i] - t[i-1] if i else 1.0 for i in range(len(t))]
bat = [i for i, r in enumerate(R) if f(r, 'EM:CPU Energy') * dt[i] > 100]
grp = []
for i in bat:
    if grp and i - grp[-1][-1] <= 3: grp[-1].append(i)
    else: grp.append([i])
edges = [(-1, None)] + [(g[-1], g) for g in grp]
for w in range(1, len(edges)):
    a0, _ = edges[w-1]; b0, g = edges[w]; rng = range(a0 + 1, b0)
    span = sum(dt[i] for i in rng); full = a0 >= 0
    E = {k: sum(f(R[i], 'EM:'+k) * dt[i] for i in g) for k in ('CPU Energy', 'EACC_CPU', 'PACC0_CPU', 'PACC1_CPU', 'GPU0')}
    pacc = E['PACC0_CPU'] + E['PACC1_CPU']
    print(f"\n=== 窗口 {w}: {time.strftime('%H:%M:%S', time.localtime(t[a0+1]))} → {time.strftime('%H:%M:%S', time.localtime(t[b0]))}  覆盖 {span:.0f} s {'（完整）' if full else '（CSV 开头起，不完整 → 估算为下限）'}")
    agx = sum(f(R[i], 'EM:GPU Energy') * dt[i] for i in rng)
    print('  PMGR: ' + ', '.join(f"{k}={v:.0f} J" for k, v in E.items()) + f"；AGX 实时积分={agx:.0f} J（GPU0/AGX={E['GPU0']/agx if agx else float('nan'):.3f}）")
    idle = [i for i in rng if f(R[i], 'util_c1') < a.pidle and f(R[i], 'util_c2') < a.pidle]
    for key in ('PSVR', 'PSVC', 'PZC0', 'PZC1', 'PHPC'):
        if key not in ix or not idle: continue
        c = st.median([f(R[i], key) - f(R[i], 'EM:GPU Energy') for i in idle])
        est = sum(max(0.0, f(R[i], key) - f(R[i], 'EM:GPU Energy') - c) * dt[i] for i in rng)
        lo = sum(max(0.0, f(R[i], key) - f(R[i], 'EM:GPU Energy') - c - 0.1) * dt[i] for i in rng)
        hi = sum(max(0.0, f(R[i], key) - f(R[i], 'EM:GPU Energy') - c + 0.1) * dt[i] for i in rng)
        print(f"  P 簇 {key}: c={c:.2f} W → {est:.0f} J，/PACC0+1={est/pacc:.3f}（c±0.1 W: {lo/pacc:.3f}–{hi/pacc:.3f}）")
    if 'PPSR' in ix:
        eidle = [i for i in rng if f(R[i], 'util_c0') < 0.25 and f(R[i], 'util_c1') < a.pidle and f(R[i], 'util_c2') < a.pidle]
        for k in (0.0, 0.034):
            if not eidle: break
            c = st.median([f(R[i], 'PPSR') - k * f(R[i], 'EM:GPU Energy') for i in eidle])
            est = sum(max(0.0, f(R[i], 'PPSR') - k * f(R[i], 'EM:GPU Energy') - c) * dt[i] for i in rng)
            print(f"  E 簇 PPSR（GPU 系数 {k}）: c={c:.3f} W（{len(eidle)} 秒）→ {est:.0f} J，/EACC={est/E['EACC_CPU']:.3f}")
    print(f"  平均占用 E={st.mean(f(R[i],'util_c0') for i in rng):.3f} P1={st.mean(f(R[i],'util_c1') for i in rng):.3f} P2={st.mean(f(R[i],'util_c2') for i in rng):.3f}")
