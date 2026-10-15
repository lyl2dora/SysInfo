#!/usr/bin/env python3
# analyze_r2.py - 第二轮：RP* 功耗轨与 PMGR 批次对账（K35），以及遥测累加器在高负载下是否丢计数。
# usage: analyze_r2.py <dir> <tag>
import csv, sys, re, time, numpy as np
D, TAG = sys.argv[1], sys.argv[2]
rows = list(csv.reader(open(f'{D}/pt_{TAG}.csv'))); H = rows[0]; rows = [r for r in rows[1:] if len(r) == len(H)]
X = {k: np.array([float(r[j]) if r[j] not in ('nan', '') else np.nan for r in rows]) for j, k in enumerate(H) if k != 'epoch' or True}
t = X['epoch']
blocks = []; cur = None
for line in open(f'{D}/pt_{TAG}_pmgr.txt'):
    line = line.rstrip('\n')
    if line.startswith('=== '): p = line.split(); cur = [float(p[1]), int(p[3].split('=')[1]), {}]; blocks.append(cur)
    elif line.count('|') >= 3: n, u, d, v = line.split('|')[:4]; cur[2][n] = (u, int(v))
big = [b for b in blocks if b[1] >= 20]; b1, b2 = big[0], big[1]; B1, B2 = b1[0], b2[0]
dP = {n: (b2[2][n][1] - b1[2][n][1]) * {'mJ': 1e-3, 'uJ': 1e-6, 'nJ': 1e-9}[u] for n, (u, v) in b1[2].items() if n in b2[2]}
def integ(k, a=B1, b=B2):
    m = (t > a) & (t <= b); idx = np.where(m)[0]; prev = np.concatenate([[t[idx[0]] - 1], t[idx][:-1]]); return float(np.nansum(X[k][idx] * np.minimum(t[idx] - prev, 1.05)))
print(f'##### {TAG} 窗口 {time.strftime("%H:%M:%S", time.localtime(B1))} → {time.strftime("%H:%M:%S", time.localtime(B2))} ({B2-B1:.0f} s)')
rp = sorted(k for k in X if re.fullmatch(r'RP0.', k)); I = {k: integ(k) for k in rp + ['PZC0', 'PZD1', 'PHPC', 'PDTR']}
print('  RP 积分 (J):', {k: round(I[k], 1) for k in rp})
def cmp(lab, a, b): print(f'  {lab:44s} {a:9.1f} vs {b:9.1f} J  比值 {a/b:6.3f}')
cpuE = dP['CPU Energy']; gpu = dP.get('GPU0', dP.get('GPU')); dram = dP.get('DRAM0', dP.get('DRAM'))
agx = [v for n, v in dP.items() if n == 'GPU Energy'][0]
if TAG.startswith('m5'):
    cpu_rails = {'Super (RP00+RP01)': ['RP00', 'RP01'], 'M0 (RP02)': ['RP02'], 'M1 (RP04)': ['RP04']}
    pm = {'Super (RP00+RP01)': ['PCPU', 'PCPM'], 'M0 (RP02)': ['MCPU0', 'MCPM0'], 'M1 (RP04)': ['MCPU1', 'MCPM1']}
    gpu_rails = ['RP05', 'RP08']
else:
    cpu_rails = {'P0 (RP05+RP06)': ['RP05', 'RP06'], 'P1 (RP00+RP01)': ['RP00', 'RP01'], 'E (RP02)': ['RP02']}
    pm = {'P0 (RP05+RP06)': ['PACC0_CPU'], 'P1 (RP00+RP01)': ['PACC1_CPU'], 'E (RP02)': ['EACC_CPU']}
    gpu_rails = ['RP07', 'RP0b', 'RP0c']
tot = sum(I[k] for ks in cpu_rails.values() for k in ks)
cmp('CPU 专用轨合计 vs PMGR CPU Energy', tot, cpuE)
for lab, ks in cpu_rails.items():
    a = sum(I[k] for k in ks); b = sum(dP.get(n, 0) for n in pm[lab]); cmp(f'  {lab} vs PMGR {"+".join(pm[lab])}', a, b)
g = sum(I.get(k, 0) for k in gpu_rails)
cmp(f'GPU 轨 {"+".join(gpu_rails)} vs PMGR GPU', g, gpu); cmp('AGX GPU Energy vs PMGR GPU', agx, gpu)
cmp('PZD1 vs PMGR DRAM', I['PZD1'], dram)
top = [n for n in dP if (n == 'CPU Energy' or (re.fullmatch(r'[A-Z]+\d?', n) and 'CPU' not in n and 'CPM' not in n)) and dP[n] > 0.05]
cmp('PZC0 vs PMGR 顶层合计', I['PZC0'], sum(dP[n] for n in top)); cmp('PHPC vs PMGR 顶层合计', I['PHPC'], sum(dP[n] for n in top))
# 负载段内 CPU 轨与 AGX 的瞬时比较
ph = {}
for line in open(f'{D}/phases_{TAG}.log'):
    p = line.split()
    if p[0] == 'PHASE_START': ph.setdefault(p[1], [0, 0])[0] = float(p[2])
    if p[0] == 'PHASE_END': ph[p[1]][1] = float(p[2])
print('  负载段均值（W，跳过前 5 s）:')
for n, (a, b) in ph.items():
    m = (t >= a + 5) & (t <= b)
    print(f'    {n:9s} ' + ' '.join(f'{lab.split()[0]}={sum(np.nanmean(X[k][m]) for k in ks):5.2f}' for lab, ks in cpu_rails.items())
          + f'  GPU轨={sum(np.nanmean(X[k][m]) for k in gpu_rails if k in X):5.2f} AGX={np.nanmean(X["AGX_W"][m]):5.2f} PDTR={np.nanmean(X["PDTR"][m]):5.1f}')
# 遥测
c = X['T_SystemPowerInAccumulatorCount']; acc = X['T_AccumulatedSystemPowerIn']; up = np.where(np.diff(c) != 0)[0] + 1
bad = []
for a, b in zip(up[:-1], up[1:]):
    dC = c[b] - c[a]; m = (t > t[a]) & (t <= t[b]); E = np.sum(X['PDTR'][m]); dA = (acc[b] - acc[a]) / 1000
    if dC < 55 or abs(dA / E - 1) > 0.08: bad.append((time.strftime('%H:%M:%S', time.localtime(t[b])), int(dC), round(E / 60, 1), round(dA / 60, 1)))
print(f'  遥测 {len(up)} 次更新，异常（计数 <55 或与 PDTR 差 >8%）:', bad)
