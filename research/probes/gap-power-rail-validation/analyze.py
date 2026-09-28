#!/usr/bin/env python3
# analyze.py - offline analysis of rail.csv / rail_pmgr.txt / phases.log / load_*.txt (gap-power-rail-validation)
import csv, re, sys, os, glob, time
import numpy as np
D = os.path.dirname(os.path.abspath(__file__))
def hm(t): return time.strftime('%H:%M:%S', time.localtime(t)) + ('%.1f' % (t % 1))[1:]

# ---------- load rail.csv ----------
rows = list(csv.reader(open(f'{D}/rail.csv')))
hdr = rows[0]; data = rows[1:]
if len(data[-1]) != len(hdr): data = data[:-1]
ip = hdr.index('PMP0_means...')
cols = {}
for j, h in enumerate(hdr):
    if j == ip: continue
    cols[h] = np.array([float(r[j]) if r[j] not in ('nan', '') else np.nan for r in data])
pmpnames = [l.split(' ', 1)[1].strip() for l in open(f'{D}/rail_pmpcols.txt')] if os.path.exists(f'{D}/rail_pmpcols.txt') else []
pmp = np.array([[float(x) if x != 'nan' else np.nan for x in r[ip].lstrip('|').split(';')] + [np.nan] * (32 - len(r[ip].lstrip('|').split(';'))) for r in data])
t = cols['epoch']; dt = cols['dt']
pkeys = [h for h in hdr[3:hdr.index('AGX_GE_nJ')]]
print(f'# rail.csv: {len(t)} samples {hm(t[0])} .. {hm(t[-1])}; {len(pkeys)} SMC P* flt keys')

# ---------- PMGR change events ----------
blocks = []  # (t, kind, {name: value}, changed-line)
cur = None
for line in open(f'{D}/rail_pmgr.txt'):
    line = line.rstrip('\n')
    if line.startswith('=== '):
        p = line.split(); cur = [float(p[1]), p[2], {}, '']; blocks.append(cur)
    elif line.startswith('changed:'):
        cur[3] = line
    elif '|' in line and cur is not None:
        n, u, dv, v = line.rsplit('|', 3) if line.count('|') >= 3 else (None,)*4
        # name|unit|driver|value  (driver contains no '|')
        parts = line.split('|'); n, u, dv, v = parts[0], parts[1], parts[2], parts[3]
        cur[2][(n, dv)] = (u, int(v))
print('\n# PMGR change events (1 Hz detection; value = delta vs previous sample)')
for b in blocks:
    if b[1] == 'CHANGE':
        ch = dict(re.findall(r' (CPU Energy|GPU0|ANE0|DRAM0|AVE0|PCPU|MCPU0|MCPU1)([+-]\d+)', b[3]))
        n = b[3].count(' ')
        print(f'  {hm(b[0])}  nchanged={n:3d}  ' + '  '.join(f'{k}{v}mJ' for k, v in ch.items()))
changes = [b for b in blocks if b[1] == 'CHANGE']
bigs = [b for b in changes if b[3].count(' ') > 50]
print('  major batches at:', ', '.join(hm(b[0]) for b in bigs))
if len(bigs) >= 2:
    print('  batch spacing (s):', [round(bigs[i+1][0] - bigs[i][0], 1) for i in range(len(bigs) - 1)])

def state_after(tq, settle=60):
    """PMGR state (dict) as of tq+settle: last block with time <= tq+settle"""
    best = None
    for b in blocks:
        if b[0] <= tq + settle: best = b
    return best

def agx_at(tq):
    i = np.searchsorted(t, tq); i = min(max(i, 0), len(t) - 1); return cols['AGX_GE_nJ'][i], t[i]

if len(bigs) < 2:
    print('!! need two major batches for window analysis'); W = None
else:
    # choose the window 18:08:29 -> 18:38:29 (the last two major batches)
    B1, B2 = bigs[-2][0], bigs[-1][0]
    W = (B1, B2)
    s1, s2 = state_after(B1), state_after(B2)
    print(f'\n# WINDOW {hm(B1)} -> {hm(B2)} ({B2 - B1:.0f} s); PMGR state taken at last event <= batch+60 s: {hm(s1[0])} / {hm(s2[0])}')
    dP = {}
    for k, (u, v2) in s2[2].items():
        if k in s1[2]:
            v1 = s1[2][k][1]
            scale = {'mJ': 1e-3, 'uJ': 1e-6, 'nJ': 1e-9}.get(u, np.nan)
            dP[k[0] if 'PMGR' in k[1] else k[0] + ' [' + k[1].split(' <')[0] + ']'] = (v2 - v1) * scale
    L = B2 - B1
    main = ['CPU Energy', 'PCPU', 'MCPU0', 'MCPU1', 'PCPM', 'MCPM0', 'MCPM1', 'GPU0', 'ANE0', 'DRAM0', 'AVE0', 'AMCC0', 'DCS0', 'FAB0', 'AFR0', 'DISP0', 'DISPEXT0', 'ISP0', 'MSR0']
    print('  PMGR/other Energy Model deltas over window (J, mean W):')
    for k in main + sorted(k for k in dP if k not in main and not re.search(r'DTL|_\d|SRAM', k)):
        if k in dP: print(f'    {k:40s} {dP[k]:10.1f} J  {dP[k]/L:7.3f} W')
    sram = sum(v for k, v in dP.items() if 'SRAM' in k and 'PMGR' not in k)
    pmgr_all = {k: v for k, v in dP.items() if '[' not in k}
    def S(*ks): return sum(dP.get(k, 0) for k in ks)
    # top-level (non-leaf) PMGR rails: exclude per-core leafs (_0.._5), DTL, *_SRAM
    top = {k: v for k, v in pmgr_all.items() if not re.search(r'DTL|_\d|SRAM|^CPU Energy$', k)}
    print('  sum of top-level PMGR rails (excl CPU Energy aggregate, per-core leafs, DTL, SRAM):', round(sum(top.values()), 1), 'J', {k: round(v, 1) for k, v in sorted(top.items(), key=lambda x: -x[1])})
    agx1, ta = agx_at(B1); agx2, tb = agx_at(B2)
    dAGX = (agx2 - agx1) / 1e9
    print(f'  AGX GPU Energy (live) over same window: {dAGX:.1f} J ({dAGX/L:.3f} W)  vs PMGR GPU0 {dP.get("GPU0",0):.1f} J')
    # SMC integrals
    m = (t > B1) & (t <= B2)
    print(f'\n  SMC integrals over window ({m.sum()} samples, sum dt={dt[m].sum():.1f} s):')
    ints = {}
    for k in pkeys:
        e = np.nansum(cols[k][m] * dt[m]); ints[k] = e
    for k in ['PHPC', 'PPSM', 'PMVC', 'PSTR', 'PDTR', 'PD0R', 'Pb0f', 'PZC0', 'PZC1', 'PPMR', 'PHPM', 'PPSR', 'PPTR', 'PP9b', 'PP0b', 'PN00', 'PO5R', 'PZD1']:
        print(f'    {k}: {ints[k]:9.1f} J  mean {ints[k]/L:7.3f} W')
    others = sorted(((ints[k], k) for k in pkeys if k not in ('PZT0',)), reverse=True)
    print('    all P* keys by integral (J):', ', '.join(f'{k}={v:.0f}' for v, k in others if v > 5))
    # PMP0 histogram-mean integrals
    if pmpnames:
        print('  PMP0 Energy histogram-mean integrals (J):')
        pe = {}
        for i, n in enumerate(pmpnames):
            if not n.startswith('Energy:'): continue
            pe[n] = np.nansum(pmp[m, i] * dt[m]); print(f'    {n:22s} {pe[n]:8.1f} J  mean {pe[n]/L:6.3f} W')
        cpuPMP = sum(v for k, v in pe.items() if re.search('MACC|PACC', k))
        gpuPMP = sum(v for k, v in pe.items() if 'AGX' in k)
        print(f'    PMP CPU clusters (MACC0+MACC1+PACC incl SRAM) = {cpuPMP:.1f} J ; PMP AGX+AFR = {gpuPMP:.1f} J')
    # Telemetry
    Tacc, Tcnt = cols['T_AccumulatedSystemPowerIn'], cols['T_SystemPowerInAccumulatorCount']
    Twall = cols['T_AccumulatedWallEnergyEstimate']; Tsys = cols['T_AccumulatedSystemEnergyConsumed']
    # telemetry updates: rows where count changes
    upd = np.where(np.diff(Tcnt) != 0)[0] + 1
    ui = [i for i in upd if B1 - 1 <= t[i] <= B2 + 90]
    if len(ui) >= 2:
        # pick the update closest to B1 and to B2
        i1 = min(ui, key=lambda i: abs(t[i] - B1)); i2 = min(ui, key=lambda i: abs(t[i] - B2))
        dAcc = (Tacc[i2] - Tacc[i1]) / 1000.0; dC = Tcnt[i2] - Tcnt[i1]
        dW = (Twall[i2] - Twall[i1]) * 3.6; dS = (Tsys[i2] - Tsys[i1]) * 3.6
        mm = (t > t[i1] - 60) & (t <= t[i2] - 60)  # telemetry accumulator lags ~60 s: compare PDTR over the shifted span too
        m2 = (t > t[i1]) & (t <= t[i2])
        print(f'\n  PowerTelemetryData between updates seen at {hm(t[i1])} and {hm(t[i2])}: dCount={dC:.0f} s')
        print(f'    AccumulatedSystemPowerIn: {dAcc:.1f} J (mean {dAcc/dC:.3f} W) | AccumulatedSystemEnergyConsumed*3.6: {dS/1000:.1f} J | AccumulatedWallEnergyEstimate*3.6: {dW/1000:.1f} J (mean {dW/1000/dC:.3f} W)')
        print(f'    SMC PDTR over the same wall span: {np.nansum(cols["PDTR"][m2]*dt[m2]):.1f} J ; over span shifted -60 s: {np.nansum(cols["PDTR"][mm]*dt[mm]):.1f} J')
    # Summary ratios
    print('\n  RATIOS (window):')
    cpu = dP.get('CPU Energy', np.nan); gpu = dP.get('GPU0', np.nan); ane = dP.get('ANE0', 0); dram = dP.get('DRAM0', 0); ave = dP.get('AVE0', 0)
    for lab, val in [('CPU', cpu), ('CPU+GPU0', cpu + gpu), ('CPU+AGX', cpu + dAGX), ('CPU+GPU0+ANE0', cpu + gpu + ane), ('CPU+GPU0+ANE0+AVE0', cpu + gpu + ane + ave),
                     ('CPU+GPU0+ANE0+DRAM0', cpu + gpu + ane + dram), ('CPU+GPU0+ANE0+DRAM0+AVE0', cpu + gpu + ane + dram + ave), ('all top-level PMGR', sum(top.values()) + 0)]:
        print(f'    {lab:28s} {val:9.1f} J   PHPC/x={ints["PHPC"]/val:6.3f}  PMVC/x={ints["PMVC"]/val:6.3f}  PDTR/x={ints["PDTR"]/val:6.3f}  PZC0/x={ints["PZC0"]/val:6.3f} PZC1/x={ints["PZC1"]/val:6.3f}')
    print(f'    PHPC - AGX = {ints["PHPC"] - dAGX:.1f} J vs PMGR CPU Energy {cpu:.1f} J (ratio {(ints["PHPC"]-dAGX)/cpu:.3f})')

# ---------- phases ----------
ph = {}
if os.path.exists(f'{D}/phases.log'):
    for l in open(f'{D}/phases.log'):
        p = l.split()
        if p[0] == 'PHASE_START': ph.setdefault(p[1], {})['s'] = float(p[2])
        if p[0] == 'PHASE_END': ph.setdefault(p[1], {})['e'] = float(p[2])
def mean_in(k, a, b, arr=None):
    mm = (t >= a) & (t <= b); x = (cols[k] if arr is None else arr)[mm]; return np.nanmean(x) if mm.any() else np.nan
def base_in(k, spans, arr=None):
    mm = np.zeros(len(t), bool)
    for a, b in spans: mm |= (t >= a) & (t <= b)
    x = (cols[k] if arr is None else arr)[mm]; return np.nanmedian(x) if mm.any() else np.nan
def proc_power(name, a, b):
    f = f'{D}/load_{name}.txt'
    if not os.path.exists(f): return (np.nan,) * 4
    S = []
    for l in open(f):
        if l.startswith('S ') or l.startswith('FINAL '):
            p = l.split(); tt = float(p[1]); kv = dict(x.split('=') for x in p[2:] if '=' in x)
            S.append((tt, float(kv['energy_nj']), float(kv['penergy_nj']), float(kv['user_s']) + float(kv['sys_s']), float(kv['user_ptime_s']) + float(kv['sys_ptime_s'])))
    S = np.array(S)
    if len(S) < 3: return (np.nan,) * 4
    ia = np.searchsorted(S[:, 0], a); ib = np.searchsorted(S[:, 0], b) - 1
    ia = min(ia, len(S) - 1); ib = max(ib, ia)
    d = S[ib] - S[ia]
    if d[0] <= 0: return (np.nan,) * 4
    return d[1] / 1e9 / d[0], d[2] / 1e9 / d[0], d[3] / d[0], (d[4] / d[3] if d[3] > 0 else np.nan)
if ph:
    names = [n for n in ph if 's' in ph[n] and 'e' in ph[n]]
    names.sort(key=lambda n: ph[n]['s'])
    keys = ['PHPC', 'PMVC', 'PSTR', 'PDTR', 'PZC0', 'PZC1', 'PPMR', 'PHPM', 'Pb0f', 'AGX_W']
    print('\n# PER-PHASE (steady window = start+15 s .. end-5 s; baseline = MEDIAN over pre-gap [start-65,start-5] and post-gap [end+15,end+75])')
    print('  phase         ' + ' '.join(f'{k:>7s}' for k in keys) + '   | procW  procPW  cpus  Pfrac | dPHPC-dAGX  PMP_CPU  PMP_AGX')
    prev_end = W[0] if W else t[0]
    moving = {}
    pmpCPUarr = np.nansum(pmp[:, [i for i, n in enumerate(pmpnames) if re.search('Energy:(MACC|PACC)', n)]], axis=1) if pmpnames else None
    pmpAGXarr = np.nansum(pmp[:, [i for i, n in enumerate(pmpnames) if re.search('Energy:AGX', n)]], axis=1) if pmpnames else None
    for n in names:
        s, e = ph[n]['s'], ph[n]['e']
        a, b = s + 15, e - 5
        ba, bb = max(prev_end + 20, s - 65), s - 5
        nxt = [ph[x]['s'] for x in names if ph[x]['s'] > s]
        spans = [(ba, bb), (e + 15, min(e + 75, (nxt[0] - 5) if nxt else e + 75))]
        base = {k: base_in(k, spans) for k in keys}; load = {k: mean_in(k, a, b) for k in keys}
        pw, ppw, ncpu, pfrac = proc_power(n, a, b)
        dd = {k: load[k] - base[k] for k in keys}
        pc = mean_in(None, a, b, pmpCPUarr) - base_in(None, spans, pmpCPUarr) if pmpCPUarr is not None else np.nan
        pg = mean_in(None, a, b, pmpAGXarr) - base_in(None, spans, pmpAGXarr) if pmpAGXarr is not None else np.nan
        print(f'  {n:12s} base ' + ' '.join(f'{base[k]:7.2f}' for k in keys))
        print(f'  {"":12s} load ' + ' '.join(f'{load[k]:7.2f}' for k in keys) + f'   | {pw:5.2f}  {ppw:5.2f}  {ncpu:5.2f}  {pfrac:4.2f}')
        print(f'  {"":12s} DELTA' + ' '.join(f'{dd[k]:7.2f}' for k in keys) + f'   |                              | {dd["PHPC"]-dd["AGX_W"]:7.2f}  {pc:7.2f}  {pg:7.2f}')
        # which P keys move
        mv = []
        for k in pkeys:
            d = mean_in(k, a, b) - base_in(k, spans)
            if abs(d) > 0.15: mv.append(f'{k}{d:+.2f}')
        print(f'  {"":12s} P* keys moving >0.15 W: ' + ' '.join(mv))
        prev_end = e

# ---------- 10 Hz stretch ----------
m10 = cols['rate'] == 10
if m10.any():
    print('\n# 10 Hz stretch', hm(t[m10][0]), '..', hm(t[m10][-1]), f'({m10.sum()} samples)')
    for k in ['PHPC', 'PMVC', 'PSTR', 'PDTR', 'PZC0', 'PZC1', 'Pb0f', 'AGX_W']:
        x = cols[k][m10]; ch = np.sum(np.abs(np.diff(x)) > 1e-6)
        tt = t[m10]; idx = np.where(np.abs(np.diff(x)) > 1e-6)[0]
        gaps = np.diff(tt[idx + 1]) if len(idx) > 2 else []
        print(f'  {k:6s}: {ch:3d} value changes in {tt[-1]-tt[0]:.1f} s -> median interval between changes {np.median(gaps) if len(gaps) else np.nan:.2f} s; range {np.nanmin(x):.2f}..{np.nanmax(x):.2f}')
# PSTR vs PDTR lag
x, y = cols['PDTR'], cols['PSTR']
m1 = cols['rate'] == 1
xs, ys = x[m1], y[m1]
print('\n# PSTR vs PDTR (1 Hz samples): mean abs diff at lag L (PSTR[i] vs PDTR[i-L])')
for L in range(0, 4):
    print(f'  lag {L}s: {np.nanmean(np.abs(ys[L:] - xs[:len(xs)-L])):.3f} W   corr {np.corrcoef(ys[L:], xs[:len(xs)-L])[0,1]:.4f}')
print('# PPSM vs PHPC max abs diff:', np.nanmax(np.abs(cols['PPSM'] - cols['PHPC'])), '; PD0R vs PDTR:', np.nanmax(np.abs(cols['PD0R'] - cols['PDTR'])), '; Pb0f-PDTR mean', np.nanmean(cols['Pb0f'] - cols['PDTR']))
for L in range(0, 3):
    print(f'  Pb0f vs PDTR lag {L}: mean abs diff {np.nanmean(np.abs(cols["Pb0f"][m1][L:] - xs[:len(xs)-L])):.3f}')
