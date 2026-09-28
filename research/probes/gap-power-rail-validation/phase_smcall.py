# phase_smcall.py - per-phase deltas of every moving SMC flt key (smcall.csv) + AGX (rail2.csv) + own-process power for a phases log
import csv, sys, numpy as np, os
D = os.path.dirname(os.path.abspath(__file__))
plog = sys.argv[1]
r = list(csv.DictReader(open(f'{D}/smcall.csv'))); r = [x for x in r if all(v not in (None, '') for v in x.values())]
keys = [k for k in r[0] if k != 'epoch']
t = np.array([float(x['epoch']) for x in r]); A = {k: np.array([float(x[k]) for x in r]) for k in keys}
# AGX from rail2.csv
rr = list(csv.reader(open(f'{D}/rail2.csv'))); h = rr[0]; rr = [x for x in rr[1:] if len(x) == len(h)]
t2 = np.array([float(x[0]) for x in rr]); agx = np.array([float(x[h.index('AGX_W')]) if x[h.index('AGX_W')] != 'nan' else np.nan for x in rr])
ph = {}
for l in open(f'{D}/{plog}'):
    p = l.split()
    if p[0] == 'PHASE_START': ph.setdefault(p[1], {})['s'] = float(p[2])
    if p[0] == 'PHASE_END': ph.setdefault(p[1], {})['e'] = float(p[2])
def procW(n, a, b):
    S = []
    for l in open(f'{D}/load_{n}.txt'):
        if l.startswith(('S ', 'FINAL')):
            p = l.split(); kv = dict(x.split('=') for x in p[2:] if '=' in x); S.append((float(p[1]), float(kv['energy_nj'])))
    S = np.array(S); ia = np.searchsorted(S[:, 0], a); ib = np.searchsorted(S[:, 0], b) - 1
    return (S[ib, 1] - S[ia, 1]) / 1e9 / (S[ib, 0] - S[ia, 0])
names = sorted([n for n in ph if 'e' in ph[n]], key=lambda n: ph[n]['s'])
sel = [k for k in keys if k[0] in 'PR' or k.startswith(('sp', 'fd', 'fp', 'xD'))]
rows = {}
for i, n in enumerate(names):
    s, e = ph[n]['s'], ph[n]['e']; a, b = s + 15, e - 5
    pre = (t >= max(s - 60, (ph[names[i-1]]['e'] + 20) if i else s - 60)) & (t <= s - 5)
    post = (t >= e + 15) & (t <= min(e + 60, (ph[names[i+1]]['s'] - 5) if i + 1 < len(names) else e + 60))
    base = pre | post; load = (t >= a) & (t <= b)
    d = {k: A[k][load].mean() - np.median(A[k][base]) for k in sel}
    b2 = ((t2 >= s - 60) & (t2 <= s - 5)) | ((t2 >= e + 15) & (t2 <= e + 60)); l2 = (t2 >= a) & (t2 <= b)
    d['AGX_W'] = np.nanmean(agx[l2]) - np.nanmedian(agx[b2]); d['procW'] = procW(n, a, b)
    rows[n] = d
cols = ['procW', 'AGX_W'] + sel
print('key      ' + ''.join(f'{n[3:] if n[2]=="_" else n:>10s}' for n in names))
for k in cols:
    vals = [rows[n][k] for n in names]
    if max(abs(v) for v in vals) < 0.05: continue
    print(f'{k:8s} ' + ''.join(f'{v:10.2f}' for v in vals))
