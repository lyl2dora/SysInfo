#!/usr/bin/env python3
"""em_window.py — 用 Energy Model（PMGR）批次校准 SMC 实时功耗键。
输入 tp_watch 的长时间 CSV（EM:* 列是每秒增量折算的 W；批次到达那一秒会出现巨大值，×dt 即该批能量 J）。
做法：找出 EM:CPU Energy 非零的秒 = 批次；相邻两批之间为一个窗口（第一个窗口从 CSV 开头算起，需注明缺口）；
窗口内对每个 P*/R* 键做 Σ value·dt 积分，与该窗口批次的 EACC_CPU / PACC0_CPU / PACC1_CPU / CPU Energy（或 M5 的 PCPU/MCPU0/MCPU1）比较。
用法：em_window.py passive.csv [--first-gap 秒]  （first-gap = CSV 开头到上一个批次的秒数，只用于提示）
"""
import csv, sys, math
fn = sys.argv[1]
rows = list(csv.reader(open(fn))); h = rows[0]; ix = {k: i for i, k in enumerate(h)}
t = [float(r[0]) for r in rows[1:]]
def col(k):
    out = []
    for r in rows[1:]:
        try: v = float(r[ix[k]]); out.append(0.0 if math.isnan(v) else v)
        except: out.append(0.0)
    return out
em = [k for k in h if k.startswith('EM:')]
emv = {k: col(k) for k in em}
dt = [t[i] - t[i - 1] if i else 1.0 for i in range(len(t))]
cpu = emv.get('EM:CPU Energy')
batches = [i for i, v in enumerate(cpu) if v > 0]
import time
print(f"rows={len(t)} span {time.strftime('%H:%M:%S', time.localtime(t[0]))} .. {time.strftime('%H:%M:%S', time.localtime(t[-1]))}")
for i in batches:
    print(f"  batch at {time.strftime('%H:%M:%S', time.localtime(t[i]))} (row {i}): " + ' '.join(f"{k[3:]}={emv[k][i]*dt[i]:.1f}J" for k in em if emv[k][i] != 0))
# 合并相邻 3 s 内的批次行
groups = []
for i in batches:
    if groups and i - groups[-1][-1] <= 3: groups[-1].append(i)
    else: groups.append([i])
edges = [0] + [g[-1] for g in groups]
pk = [k for k in h if len(k) == 4 and k[0] in 'PR' and k not in ('phase',)]
vals = {k: col(k) for k in pk}
for w in range(1, len(edges)):
    a, b = edges[w - 1], edges[w]
    span = t[b] - t[a]
    E = {k[3:]: sum(emv[k][i] * dt[i] for i in groups[w - 1]) for k in em}
    integ = {k: sum(vals[k][i] * dt[i] for i in range(a + 1, b + 1)) for k in pk}
    print(f"\n=== window {w}: {time.strftime('%H:%M:%S', time.localtime(t[a]))} -> {time.strftime('%H:%M:%S', time.localtime(t[b]))} ({span:.0f} s){'  [第一个窗口：CSV 开始前的部分未覆盖]' if w == 1 else ''}")
    print('  PMGR batch (J, mean W over window): ' + ', '.join(f"{k}={v:.0f}J/{v/span:.3f}W" for k, v in E.items() if v))
    refs = [k for k in ('CPU Energy', 'EACC_CPU', 'PACC0_CPU', 'PACC1_CPU', 'PCPU', 'MCPU0', 'MCPU1') if E.get(k)]
    pacc = (E.get('PACC0_CPU') or 0) + (E.get('PACC1_CPU') or 0)
    top = sorted(integ.items(), key=lambda kv: -abs(kv[1]))[:40]
    print('  SMC integrals (J, mean W): ' + ' '.join(f"{k}={v:.0f}/{v/span:.2f}" for k, v in top))
    cand = ['PSVR', 'PSVC', 'PR0b', 'PR1b', 'PR8b', 'PP3b', 'PP9b', 'PPSR', 'PMVR', 'PHPC', 'PHPS', 'PZC0', 'PZC1', 'PDTR', 'RP00', 'RP01', 'RP02', 'RP04', 'PP0b', 'PP1b']
    for c in cand:
        if c not in integ or not integ[c]: continue
        s = '  ' + f"{c}: {integ[c]:.0f} J;"
        for r in refs: s += f" /{r}={integ[c]/E[r]:.3f}"
        if pacc: s += f" /(PACC0+PACC1)={integ[c]/pacc:.3f}"
        print(s)
    if 'PSVR' in integ and pacc:
        for extra in ('PR0b', 'PPSR', 'PR8b', 'PP9b'):
            if extra in integ:
                print(f"  PSVR+{extra} = {integ['PSVR']+integ[extra]:.0f} J  /CPU Energy={(integ['PSVR']+integ[extra])/E['CPU Energy']:.3f};  PSVC+{extra} /CPU Energy={(integ['PSVC']+integ[extra])/E['CPU Energy']:.3f}")
