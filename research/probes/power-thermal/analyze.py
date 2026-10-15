#!/usr/bin/env python3
# analyze.py - 功耗与散热补测分析。usage: analyze.py <dir> <tag> [boot_epoch]
# 输出：批次相位、完整窗口对账（SMC 积分 vs PMGR 差分、PDTR vs PowerTelemetryData）、
# 各负载段的功耗键均值、温度键升幅与占位值、风扇、热压力、读取开销。
import csv, sys, os, re, itertools, time
import numpy as np

D, TAG = sys.argv[1], sys.argv[2]
BOOT = float(sys.argv[3]) if len(sys.argv) > 3 else None
def hm(t): return time.strftime('%H:%M:%S', time.localtime(t))

rows = list(csv.reader(open(f'{D}/pt_{TAG}.csv'))); H = rows[0]; rows = [r for r in rows[1:] if len(r) == len(H)]
X = {}
for j, k in enumerate(H):
    try: X[k] = np.array([float(r[j]) if r[j] not in ('nan', '') else np.nan for r in rows])
    except ValueError: pass
t = X['epoch']

def load_pmgr(fn):
    blocks = []; cur = None
    for line in open(fn):
        line = line.rstrip('\n')
        if line.startswith('=== '):
            p = line.split(); cur = [float(p[1]), p[2], {}, int(p[3].split('=')[1]) if len(p) > 3 and '=' in p[3] else 0]; blocks.append(cur)
        elif line.count('|') >= 3 and cur is not None:
            n, u, dv, v = line.split('|')[:4]; cur[2][(n, dv.split(' <')[0])] = (u, int(v))
    return blocks
P = load_pmgr(f'{D}/pt_{TAG}_pmgr.txt')
ph = {}
for line in open(f'{D}/phases_{TAG}.log'):
    p = line.split()
    if p[0] == 'PHASE_START': ph.setdefault(p[1], [None, None])[0] = float(p[2])
    if p[0] == 'PHASE_END': ph.setdefault(p[1], [None, None])[1] = float(p[2])

print(f'##### {TAG}: {len(t)} 行, {hm(t[0])} → {hm(t[-1])}, {len([k for k in X if re.fullmatch(r"[PTFVI]...", k)])} 个 SMC 键')

# ---- 1. 批次 ----
ch = [b for b in P if b[1] == 'CHANGE']
big = [b for b in ch if b[3] >= 20]
print('\n[批次] PMGR 变化事件:', ', '.join(f'{hm(b[0])}(n={b[3]})' for b in ch))
for i in range(1, len(big)): print(f'  批次间隔 {big[i][0] - big[i-1][0]:.1f} s')
if BOOT:
    for b in big: print(f'  相位：开机 + {(b[0] - BOOT) % 1800:.0f} s (mod 1800)')

# ---- 2. 窗口对账 ----
def integ(key, a, b):
    m = (t > a) & (t <= b); idx = np.where(m)[0]
    if not len(idx): return np.nan
    prev = np.concatenate([[t[idx[0]] - 1.0], t[idx][:-1]]); dt = np.minimum(t[idx] - prev, 1.05)
    return float(np.nansum(X[key][idx] * dt))
if len(big) >= 2:
    b1, b2 = big[0], big[1]; B1, B2 = b1[0], b2[0]; L = B2 - B1
    print(f'\n[窗口] {hm(B1)} → {hm(B2)}（{L:.0f} s）')
    dP = {}
    for k, (u, v2) in b2[2].items():
        if k in b1[2]:
            sc = {'mJ': 1e-3, 'uJ': 1e-6, 'nJ': 1e-9}.get(u, np.nan); nm = k[0] if 'PMGR' in k[1] else f'{k[0]} [{k[1]}]'
            dP[nm] = (v2 - b1[2][k][1]) * sc
    top = [n for n, v in dP.items() if (n == 'CPU Energy' or (re.fullmatch(r'[A-Z]+\d?', n) and 'CPU' not in n and 'CPM' not in n and '[' not in n)) and abs(v) > 0.05]
    print('  PMGR 顶层通道 (J):', {k: round(dP[k], 1) for k in sorted(top, key=lambda k: -dP[k])}, ' 合计', round(sum(dP[k] for k in top), 1))
    cl = {n: round(v, 1) for n, v in dP.items() if re.fullmatch(r'[A-Z]*CP[UM]\d?', n)}
    print('  PMGR CPU 簇级通道 (J):', cl)
    agx = [v for n, v in dP.items() if n.startswith('GPU Energy')]
    print('  非 PMGR 通道 (J):', {n: round(v, 1) for n, v in dP.items() if '[' in n and abs(v) > 0.01})
    I = {}
    for k in ['PDTR', 'PSTR', 'PHPC', 'PZC0', 'PZC1', 'PZD1', 'PPSR', 'PPMR', 'PPTR', 'PMVC', 'PHPS', 'PHPM', 'PHPB', 'PD0R', 'PZT0', 'PZCB', 'PZCU', 'PH2R', 'PH3R'] + [k for k in X if re.fullmatch(r'RP0.', k)]:
        if k in X: I[k] = integ(k, B1, B2)
    print('  SMC 窗口均值 (W):', {k: round(v / L, 3) for k, v in I.items()})
    def cmp(lab, a, b): print(f'  {lab:48s} SMC {a:9.1f} J  PMGR {b:9.1f} J  比值 {a/b if b else np.nan:6.3f}')
    S = sum(dP[k] for k in top)
    dram = dP.get('DRAM0', dP.get('DRAM')); gpu = dP.get('GPU0', dP.get('GPU'))
    if 'PZD1' in I and dram: cmp('PZD1 vs DRAM', I['PZD1'], dram)
    if 'PZC0' in I: cmp('PZC0 vs 顶层合计', I['PZC0'], S)
    if 'PHPC' in I: cmp('PHPC vs 顶层合计', I['PHPC'], S)
    if agx and gpu: cmp('AGX GPU Energy vs PMGR GPU', agx[0], gpu)
    for key in ['PZC0', 'PHPC']:
        if key not in I: continue
        e = I[key]; res = []
        for r in range(1, min(len(top), 7) + 1):
            for c in itertools.combinations(top, r):
                s = sum(dP[x] for x in c); res.append((abs(s - e) / e, s, c))
        res.sort(); print(f'  {key} {e:.1f} J 最接近的 PMGR 子集:')
        for err, s, c in res[:3]: print(f'     {err*100:6.2f}%  {s:9.1f}  {"+".join(c)}')
    print('  单键最接近的 PMGR 通道:')
    for k in [k for k in I if k.startswith('RP')] + ['PZD1', 'PPSR', 'PHPC', 'PZC0']:
        if k not in I or not I[k]: continue
        e = I[k]; best = sorted(dP.items(), key=lambda kv: abs(kv[1] - e))[:3]
        print(f'    {k:5s} {e:8.1f} → ' + '  '.join(f'{n}={v:.1f}({(e-v)/v*100 if v else 0:+.0f}%)' for n, v in best))
    # PDTR vs 遥测累加器（AccumulatedSystemPowerIn 单位按 mW·计数间隔推断）
    a = X['T_AccumulatedSystemPowerIn']; c = X['T_SystemPowerInAccumulatorCount']; w = X['T_AccumulatedWallEnergyEstimate']
    m = (t > B1) & (t <= B2); i0, i1 = np.where(m)[0][[0, -1]]
    dA, dC, dW = a[i1] - a[i0], c[i1] - c[i0], w[i1] - w[i0]; span = t[i1] - t[i0]
    pd = integ('PDTR', t[i0], t[i1])
    print(f'  遥测: ΔAccSysPowerIn={dA:.0f} ΔCount={dC:.0f} ΔWall={dW:.0f} 跨度 {span:.0f} s; PDTR 积分 {pd:.1f} J（均值 {pd/span:.3f} W）')
    if dC: print(f'    ΔAcc/ΔCount = {dA/dC:.1f}（若为 mW 则 {dA/dC/1000:.3f} W）；ΔWall/span×3.6 = {dW/span*3.6/1000:.3f} W? ；ΔWall×3.6/span/1000 → 见下')
    for sc_lab, sc in [('mWh→J ×3.6', 3.6), ('mJ', 1e-3), ('μWh ×0.0036', 0.0036)]:
        print(f'    ΔWall 按 {sc_lab}: {dW*sc:.1f} J = {dW*sc/span:.3f} W；DC/墙插 = {pd/(dW*sc) if dW else np.nan:.3f}')
    # 遥测发布节奏
    ch_t = t[1:][np.diff(c) != 0]
    if len(ch_t) > 2: print(f'    遥测更新间隔中位数 {np.median(np.diff(ch_t)):.1f} s（{len(ch_t)} 次）')

# ---- 3. 负载段 ----
pk = [k for k in ['PDTR', 'PSTR', 'PHPC', 'PZC0', 'PZD1', 'PPSR', 'PPMR', 'PMVC', 'AGX_W'] + sorted(k for k in X if re.fullmatch(r'RP0.', k)) if k in X]
def seg(a, b, k): m = (t >= a) & (t <= b); return float(np.nanmean(X[k][m])) if m.any() else np.nan
print('\n[负载段] 段内（跳过前 5 s）均值减段前 30 s 均值，W：')
print('  段名      ' + ' '.join(f'{k:>6s}' for k in pk))
order = sorted(ph, key=lambda n: ph[n][0])
for n in order:
    a, b = ph[n]; base = {k: seg(a - 30, a - 1, k) for k in pk}
    print(f'  {n:9s} ' + ' '.join(f'{seg(a + 5, b, k) - base[k]:6.2f}' for k in pk))
print('  空闲基线（第一段前 60 s 均值）: ' + ' '.join(f'{k}={seg(ph[order[0]][0] - 60, ph[order[0]][0] - 1, k):.3f}' for k in pk))
# PSTR 与 PDTR 的滞后
if 'PSTR' in X and 'PDTR' in X:
    for lag in range(0, 4):
        a_, b_ = X['PDTR'][:len(t) - lag], X['PSTR'][lag:]
        print(f'  PSTR 滞后 {lag} s：与 PDTR 平均差 {np.nanmean(np.abs(a_ - b_)):.3f} W')
if 'PHPC' in X and 'PZC0' in X:
    for lag in range(-2, 3):
        a_ = X['PHPC'][max(0, -lag):len(t) - max(0, lag)]; b_ = X['PZC0'][max(0, lag):len(t) - max(0, -lag)]
        print(f'  PZC0 相对 PHPC 滞后 {lag} s：相关 {np.corrcoef(np.nan_to_num(a_), np.nan_to_num(b_))[0,1]:.4f}，PHPC−PZC0 均值 {np.nanmean(a_ - b_):.3f} W')

# ---- 4. 温度键 ----
tk = [k for k in X if re.fullmatch(r'T...', k) and len(np.unique(X[k][~np.isnan(X[k])])) > 1 and np.nanmax(X[k]) < 150]
const = []
print(f'\n[温度] {len(tk)} 个 flt 温度键')
sent = {}
for k in tk:
    v = X[k]; vals, cnt = np.unique(v[~np.isnan(v)], return_counts=True)
    if len(vals) == 0: continue
    mx = vals[np.argmax(cnt)]; frac = cnt.max() / len(v)
    if frac > 0.2 and mx in (40.0, 0.0, -4.0): sent.setdefault(mx, []).append(k)
    if len(vals) == 1: const.append((k, vals[0]))
print('  恒定值键:', ' '.join(f'{k}={X[k][0]:g}' for k in X if re.fullmatch(r'T...', k) and k not in tk))
for v, ks in sent.items(): print(f'  >20% 样本恰好为 {v:g} 的键（{len(ks)}）:', ' '.join(ks))
print('  各段升幅最大的温度键（段末 10 s 均值 − 段前 30 s 均值；跳过占位值）：')
for n in order:
    a, b = ph[n]; rises = []
    for k in tk:
        v = X[k].copy(); v[np.isin(v, [40.0, 0.0, -4.0])] = np.nan
        r = np.nanmean(v[(t >= b - 10) & (t <= b)]) - np.nanmean(v[(t >= a - 30) & (t <= a - 1)])
        if not np.isnan(r): rises.append((r, k))
    rises.sort(reverse=True)
    print(f'    {n:9s} ' + ' '.join(f'{k}+{r:.1f}' for r, k in rises[:8]))
hot = [k for k in ['TCMb', 'TCMz', 'TVD0', 'TVDC', 'TVDP', 'TPDX', 'TRDX', 'TTDX', 'TCMx', 'TVMD'] if k in X]
print('  候选热点键每段段末 10 s 均值（°C）：')
print('    段名      ' + ' '.join(f'{k:>6s}' for k in hot))
print(f'    {"idle":9s} ' + ' '.join(f'{seg(ph[order[0]][0]-60, ph[order[0]][0]-1, k):6.1f}' for k in hot))
for n in order:
    a, b = ph[n]; print(f'    {n:9s} ' + ' '.join(f'{seg(b - 10, b, k):6.1f}' for k in hot))
allmax = np.nanmax(np.vstack([np.where(np.isin(X[k], [40.0, 0.0, -4.0]), np.nan, X[k]) for k in tk]), axis=0)
for k in hot:
    eq = np.mean(np.abs(X[k] - allmax) < 0.01); print(f'    {k} 等于全体温度键逐秒最大值的比例 {eq*100:.0f}%')
print('  全体温度键逐秒最大值：空闲 %.1f，全程最大 %.1f °C' % (seg(ph[order[0]][0]-60, ph[order[0]][0]-1, 'epoch') * 0 + np.nanmedian(allmax[t < ph[order[0]][0]]), np.nanmax(allmax)))

# ---- 5. 风扇与热压力 ----
fk = [k for k in X if k.startswith('F0') or k.startswith('F1')]
print('\n[风扇]', ' '.join(f'{k}: min {np.nanmin(X[k]):.0f} max {np.nanmax(X[k]):.0f}' for k in fk))
for n in order:
    a, b = ph[n]; print(f'  {n:9s} F0Ac 段内最大 {np.nanmax(X["F0Ac"][(t >= a) & (t <= b + 60)]):.0f}' if 'F0Ac' in X else '')
tp = X['thermal_pressure']; print('[热压力] 取值:', {int(v): int((tp == v).sum()) for v in np.unique(tp)})

# ---- 6. 开销 ----
for k in ['smc_cpu_ms', 'smc_wall_ms', 'em_cpu_ms', 'tel_cpu_ms']:
    print(f'[开销] {k}: 中位数 {np.nanmedian(X[k]):.2f} p90 {np.nanpercentile(X[k], 90):.2f}')
nk = len([k for k in X if re.fullmatch(r'[PTFVI]...', k)])
print(f'  SMC 每键 CPU ≈ {np.nanmedian(X["smc_cpu_ms"]) / nk * 1000:.1f} µs（{nk} 键）')
