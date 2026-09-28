#!/usr/bin/env python3
# winan.py - PMGR-window identity tests for windows 2 (18:38:29->19:08:29, stitched, gaps filled) and 3 (19:08:29->19:38:29, full).
# usage: winan.py <window 1|2|3>
import csv, sys, os, re, itertools, time
import numpy as np
D = os.path.dirname(os.path.abspath(__file__))
def hm(t): return time.strftime('%H:%M:%S', time.localtime(t))
def load_csv(fn, skip_cols=()):
    rows = list(csv.reader(open(fn))); h = rows[0]; rows = [r for r in rows[1:] if len(r) == len(h)]
    out = {}
    for j, k in enumerate(h):
        if k in skip_cols or k.startswith('PMP0'): continue
        try: out[k] = np.array([float(r[j]) if r[j] not in ('nan', '') else np.nan for r in rows])
        except ValueError: pass
    return out
def load_pmgr(fn):
    blocks = []; cur = None
    for line in open(fn):
        line = line.rstrip('\n')
        if line.startswith('=== '):
            p = line.split(); cur = [float(p[1]), p[2], {}]; blocks.append(cur)
        elif line.count('|') >= 3 and cur is not None:
            n, u, dv, v = line.split('|')[:4]; cur[2][(n, dv.split(' <')[0])] = (u, int(v))
    return blocks
R1 = load_csv(f'{D}/rail.csv'); R2 = load_csv(f'{D}/rail2.csv'); SA = load_csv(f'{D}/smcall.csv')
P1 = load_pmgr(f'{D}/rail_pmgr.txt'); P2 = load_pmgr(f'{D}/rail2_pmgr.txt')
ch2 = [b for b in P2 if b[1] == 'CHANGE']
chall = [b for b in P1 + P2 if b[1] == 'CHANGE']
print('PMGR batches seen:', ', '.join(f'{hm(b[0])}(+{b[0]-chall[i-1][0]:.1f}s)' if i else hm(b[0]) for i, b in enumerate(chall)))
win = int(sys.argv[1]) if len(sys.argv) > 1 else 3
if win == 3:
    b1, b2 = ch2[0], ch2[1]; startS = b1[2]
elif win == 2:
    b2 = ch2[0]; b1 = [b for b in P1 if b[1] == 'END'][0]; startS = b1[2]  # END block of first logger == post-18:38:29 state
    b1 = [chall[1][0], b1[1], b1[2]]
B1, B2 = b1[0], b2[0]; L = B2 - B1
print(f'\n=== WINDOW {win}: {hm(B1)} -> {hm(B2)} ({L:.0f} s)')
dP = {}
for k, (u, v2) in b2[2].items():
    if k in startS:
        sc = {'mJ': 1e-3, 'uJ': 1e-6, 'nJ': 1e-9}[u]; nm = k[0] if 'PMGR' in k[1] else f'{k[0]} [{k[1]}]'
        dP[nm] = (v2 - startS[k][1]) * sc
def integ(src, key, a, b):
    """integral of key over (a,b] using sample-and-hold of 1 Hz rows (value at row i covers (t[i-1], t[i]]); returns (J, covered seconds)"""
    t = src['epoch']; x = src[key]; m = (t > a) & (t <= b)
    if not m.any(): return 0.0, 0.0
    idx = np.where(m)[0]; tt = t[idx]; prev = np.concatenate([[max(a, t[idx[0]] - 1.0)], tt[:-1]])
    dt = np.minimum(tt - prev, 1.05)  # guard: never let one sample cover a gap
    return float(np.nansum(x[idx] * dt)), float(dt.sum())
def idle_level(src, key, a, b):
    t = src['epoch']; m = (t > a) & (t <= b); return float(np.nanmedian(src[key][m]))
def total(key):
    """window integral of an SMC key, stitching sources; gaps filled with median of neighbouring 120 s of data (reported)"""
    if key in SA and (key not in R2 or key.startswith(('RP', 'sp', 'fd', 'fp', 'xD'))):
        src = [SA]
    else:
        src = [R1, R2] if win == 2 else [R2]
    E = 0; cov = 0; spans = []
    for s in src:
        if key not in s: continue
        e, c = integ(s, key, B1, B2); E += e; cov += c
        t = s['epoch']; m = (t > B1) & (t <= B2)
        if m.any(): spans.append((t[m][0], t[m][-1], s))
    gap = L - cov; fill = 0
    if gap > 1.5 and spans:
        s0 = spans[0][2]; lvl = idle_level(s0, key, spans[0][0], spans[0][0] + 120)
        fill = lvl * gap; E += fill
    return E, gap, fill
top = ['CPU Energy', 'GPU0', 'ANE0', 'DRAM0', 'AVE0', 'AMCC0', 'DCS0', 'FAB0', 'AFR0', 'DISP0', 'DISPEXT0', 'ISP0', 'MSR0']
print('PMGR deltas (J):', {k: round(dP[k], 1) for k in top}, ' SUM', round(sum(dP[k] for k in top), 1))
def S(pat): return sum(v for n, v in dP.items() if re.fullmatch(pat, n))
grp = {'PACC cores': S(r'PACC_\d'), 'PCPU SRAM': S(r'PCPU\d_SRAM'), 'PCPM': dP['PCPM'], 'PCPM_SRAM': dP['PCPM_SRAM'],
       'MCPU0 cores': S(r'MCPU0_\d'), 'MCPU0 SRAM': S(r'MCPU0_\d_SRAM'), 'MCPM0': dP['MCPM0'], 'MCPM0_SRAM': dP['MCPM0_SRAM'],
       'MCPU1 cores': S(r'MCPU1_\d'), 'MCPU1 SRAM': S(r'MCPU1_\d_SRAM'), 'MCPM1': dP['MCPM1'], 'MCPM1_SRAM': dP['MCPM1_SRAM'],
       'PCPU': dP['PCPU'], 'MCPU0': dP['MCPU0'], 'MCPU1': dP['MCPU1']}
print('PMGR CPU sub-groups (J):', {k: round(v, 1) for k, v in grp.items()})
agx = dP.get('GPU Energy [AGXAcceleratorG17X]', np.nan)
print(f'AGX GPU Energy {agx:.1f} J vs GPU0 {dP["GPU0"]:.1f} J')
keys = ['PHPC', 'PMVC', 'PDTR', 'PSTR', 'PZC0', 'PZC1', 'PZD1', 'PPMR', 'PPSR', 'PPTR', 'PP0b', 'PP1b', 'PR0b', 'PR1b', 'PT0b', 'PP2b', 'PP4b',
        'PR4b', 'PT4b', 'PRbb', 'PTbb', 'RP00', 'RP01', 'RP02', 'RP03', 'RP04', 'RP05', 'RP06', 'RP07', 'RP08', 'RP09', 'RP0B', 'RP0C', 'spRX', 'spsX', 'spH0', 'xDPE', 'fdS0']
I = {}
print('\nSMC integrals over window:')
for k in keys:
    try: e, gap, fill = total(k)
    except KeyError: continue
    I[k] = e; print(f'  {k:6s} {e:9.1f} J  mean {e/L:7.3f} W' + (f'   (gap {gap:.0f} s filled with {fill:.1f} J)' if gap > 1.5 else ''))
I['RPsum'] = sum(I.get(k, 0) for k in ['RP00', 'RP01', 'RP02', 'RP03', 'RP04', 'RP05', 'RP06', 'RP07', 'RP08', 'RP09', 'RP0B', 'RP0C'])
I['RP_CPU'] = I['RP00'] + I['RP01'] + I['RP02'] + I['RP04']
I['RP_GPU'] = I['RP05'] + I['RP08']; I['RP_R'] = I['RP06'] + I['RP07'] + I['RP0B'] + I['RP0C']; I['RP_S'] = I['RP03'] + I['RP09']
print('\nHYPOTHESIS TESTS (SMC integral vs PMGR delta):')
def cmp(lab, a, b): print(f'  {lab:55s} SMC {a:9.1f} J  PMGR {b:9.1f} J  ratio {a/b if b else np.nan:6.3f}')
cmp('PZD1 vs DRAM0', I['PZD1'], dP['DRAM0'])
cmp('PZC0 vs sum of all top-level PMGR rails', I['PZC0'], sum(dP[k] for k in top))
cmp('PZC0 vs CPU+GPU0+ANE0+DRAM0+AVE0+AMCC0+DCS0+FAB0+AFR0', I['PZC0'], sum(dP[k] for k in top[:9]))
cmp('PHPC vs sum of all top-level PMGR rails', I['PHPC'], sum(dP[k] for k in top))
cmp('PHPC - AGX vs CPU Energy', I['PHPC'] - agx, dP['CPU Energy'])
cmp('RP_GPU (RP05+RP08) vs GPU0', I['RP_GPU'], dP['GPU0'])
cmp('RP00 vs PACC cores', I['RP00'], grp['PACC cores'])
cmp('RP00 vs PCPU', I['RP00'], grp['PCPU'])
cmp('RP01 vs PCPU SRAM + PCPM_SRAM', I['RP01'], grp['PCPU SRAM'] + grp['PCPM_SRAM'])
cmp('RP02 vs MCPU0 cores', I['RP02'], grp['MCPU0 cores']); cmp('RP04 vs MCPU1 cores', I['RP04'], grp['MCPU1 cores'])
cmp('RP02 vs MCPU0', I['RP02'], grp['MCPU0']); cmp('RP04 vs MCPU1', I['RP04'], grp['MCPU1'])
cmp('RP_CPU (RP00+RP01+RP02+RP04) vs CPU Energy', I['RP_CPU'], dP['CPU Energy'])
cmp('RP_R (RP06+07+0B+0C) vs DRAM0', I['RP_R'], dP['DRAM0'])
cmp('RP_R vs AMCC0+DCS0', I['RP_R'], dP['AMCC0'] + dP['DCS0'])
cmp('RP_S (RP03+RP09) vs FAB0+AFR0+ANE0+AVE0+DISP+ISP+MSR', I['RP_S'], sum(dP[k] for k in ['FAB0', 'AFR0', 'ANE0', 'AVE0', 'DISP0', 'DISPEXT0', 'ISP0', 'MSR0']))
cmp('RPsum vs sum top-level PMGR', I['RPsum'], sum(dP[k] for k in top))
cmp('RPsum + PZD1 vs sum top-level PMGR', I['RPsum'] + I['PZD1'], sum(dP[k] for k in top))
cmp('spsX vs CPU Energy + GPU0', I['spsX'], dP['CPU Energy'] + dP['GPU0'])
# single-channel nearest matches for RP / sp keys
print('\nNearest single PMGR channel for each RP*/sp* integral:')
for k in ['RP00', 'RP01', 'RP02', 'RP03', 'RP04', 'RP05', 'RP06', 'RP07', 'RP08', 'RP09', 'RP0B', 'RP0C', 'spRX', 'spsX', 'PZD1', 'PP0b', 'PP1b', 'PR0b']:
    e = I[k]; best = sorted(dP.items(), key=lambda kv: abs(kv[1] - e))[:3]
    print(f'  {k:5s} {e:8.1f} -> ' + '  '.join(f'{n}={v:.1f}({(e-v)/v*100 if v else 0:+.1f}%)' for n, v in best))
# subset search on PZC0 and PHPC
for key in ['PZC0', 'PHPC', 'RPsum']:
    e = I[key]; res = []
    for r in range(1, len(top) + 1):
        for c in itertools.combinations(top, r):
            s = sum(dP[x] for x in c); res.append((abs(s - e) / e, s, c))
    res.sort(); print(f'\n{key} {e:.1f} J best PMGR subsets:')
    for err, s, c in res[:4]: print(f'   {err*100:6.3f}%  {s:9.1f}  {"+".join(c)}')
