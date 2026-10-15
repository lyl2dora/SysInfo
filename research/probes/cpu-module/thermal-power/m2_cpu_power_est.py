#!/usr/bin/env python3
"""m2_cpu_power_est.py — 在一个 PMGR 批次窗口内检验 M2 上的实时 P 簇功耗估计：
  P_est(t) = max(0, PSVR(t) − GPU_AGX(t) − c)，c = P 簇空闲秒（两 P 簇占用 < 阈值）里 PSVR − GPU 的中位数（运行时可自学习的底噪）；
  同时给出 PSVC、PHPC、PZC0 的同类估计，以及 E 簇候选（PPSR − 其空闲中位数）。
与该窗口 PMGR 批次的 PACC0_CPU+PACC1_CPU（J）、EACC_CPU（J）对比。
用法：m2_cpu_power_est.py watch.csv [--pidle 0.02]
"""
import csv, sys, math, statistics as st, time, argparse
ap = argparse.ArgumentParser(); ap.add_argument('csv'); ap.add_argument('--pidle', type=float, default=0.02); a = ap.parse_args()
rows = list(csv.reader(open(a.csv))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}
def f(r, k):
    try: v = float(r[ix[k]]); return 0.0 if math.isnan(v) else v
    except: return 0.0
t = [float(r[0]) for r in rows[1:]]; R = rows[1:]
dt = [t[i] - t[i - 1] if i else 1.0 for i in range(len(t))]
batches = [i for i, r in enumerate(R) if f(r, 'EM:CPU Energy') > 0]
grp = []
for i in batches:
    if grp and i - grp[-1][-1] <= 3: grp[-1].append(i)
    else: grp.append([i])
print('batches:', [time.strftime('%H:%M:%S', time.localtime(t[g[0]])) for g in grp])
if len(grp) < 2: print('需要两个批次才能构成完整窗口'); sys.exit()
for w in range(1, len(grp)):
    a0, b0 = grp[w - 1][-1], grp[w][-1]
    rng = range(a0 + 1, b0 + 1); span = t[b0] - t[a0]
    E = {k: sum(f(R[i], 'EM:' + k) * dt[i] for i in grp[w]) for k in ('CPU Energy', 'EACC_CPU', 'PACC0_CPU', 'PACC1_CPU', 'GPU0', 'DRAM0')}
    pacc = E['PACC0_CPU'] + E['PACC1_CPU']
    agx = sum(f(R[i], 'EM:GPU Energy') * dt[i] for i in rng)
    print(f"\n=== 窗口 {time.strftime('%H:%M:%S', time.localtime(t[a0]))} → {time.strftime('%H:%M:%S', time.localtime(t[b0]))} ({span:.0f} s)")
    print('  PMGR: ' + ', '.join(f"{k}={v:.0f} J ({v/span:.3f} W)" for k, v in E.items()) + f";  AGX GPU Energy(实时) 积分={agx:.0f} J，PMGR GPU0/AGX={E['GPU0']/agx if agx else float('nan'):.3f}")
    idle = [i for i in rng if f(R[i], 'util_c1') < a.pidle and f(R[i], 'util_c2') < a.pidle]
    print(f"  P 簇空闲秒数={len(idle)}/{len(rng)}")
    for key in ('PSVR', 'PSVC', 'PHPC', 'PZC0'):
        if key not in ix: continue
        c = st.median([f(R[i], key) - f(R[i], 'EM:GPU Energy') for i in idle]) if idle else 0
        raw = sum(f(R[i], key) * dt[i] for i in rng)
        est = sum(max(0.0, f(R[i], key) - f(R[i], 'EM:GPU Energy') - c) * dt[i] for i in rng)
        est0 = sum(max(0.0, f(R[i], key) - f(R[i], 'EM:GPU Energy')) * dt[i] for i in rng)
        print(f"  {key}: 原值积分={raw:.0f} J；减 GPU={est0:.0f} J (/PACC={est0/pacc:.3f}, /CPU={est0/E['CPU Energy']:.3f})；"
              f"减 GPU 再减底噪 c={c:.2f} W → {est:.0f} J (/PACC0+1={est/pacc:.3f}, /CPU Energy={est/E['CPU Energy']:.3f})")
    for key in ('PPSR', 'PMVR', 'PR0b'):
        if key not in ix: continue
        eidle = [i for i in rng if f(R[i], 'util_c0') < 0.15 and f(R[i], 'util_c1') < a.pidle and f(R[i], 'util_c2') < a.pidle]
        c = st.median([f(R[i], key) for i in eidle]) if eidle else 0
        est = sum(max(0.0, f(R[i], key) - c) * dt[i] for i in rng); raw = sum(f(R[i], key) * dt[i] for i in rng)
        print(f"  E 簇候选 {key}: 原值={raw:.0f} J (/EACC={raw/E['EACC_CPU']:.3f})；减空闲中位数 {c:.2f} W（{len(eidle)} 秒）→ {est:.0f} J (/EACC={est/E['EACC_CPU']:.3f})")
    # 按簇拆分（推断）：w_c = util_c × V_c²，V_c 取与该簇相关的电压键均值（相关性分析得出：VC02/VC03 ↔ cluster-id 1，VC00/VC01 ↔ cluster-id 2）
    if 'VC00' in ix and 'PSVR' in ix:
        c = st.median([f(R[i], 'PSVR') - f(R[i], 'EM:GPU Energy') for i in idle]) if idle else 0
        e1 = e2 = 0.0
        for i in rng:
            p = max(0.0, f(R[i], 'PSVR') - f(R[i], 'EM:GPU Energy') - c)
            v1 = (f(R[i], 'VC02') + f(R[i], 'VC03')) / 2; v2 = (f(R[i], 'VC00') + f(R[i], 'VC01')) / 2
            w1 = f(R[i], 'util_c1') * v1 * v1; w2 = f(R[i], 'util_c2') * v2 * v2
            if w1 + w2 > 0: e1 += p * dt[i] * w1 / (w1 + w2); e2 += p * dt[i] * w2 / (w1 + w2)
        print(f"  拆分（util×V² 权重）：cluster-id1={e1:.0f} J vs PACC0={E['PACC0_CPU']:.0f} J（{e1/E['PACC0_CPU']:.3f}）；cluster-id2={e2:.0f} J vs PACC1={E['PACC1_CPU']:.0f} J（{e2/E['PACC1_CPU']:.3f}）")
