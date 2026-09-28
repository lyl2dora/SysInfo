# regress.py - per-second least-squares decomposition of aggregate SMC power keys into the other P* keys (window 1, 1 Hz rows only)
import numpy as np
exec(open('analyze.py').read().split('# ---------- phases ----------')[0].replace("print(","(lambda *a, **k: None)("))
m = (t > W[0]) & (t <= W[1]) & (cols['rate'] == 1)
agg = ['PMVC','PDTR','PD0R','PSTR','Pb0f','PHPC','PPSM','PZC0','PZC1','PZT0','PPMR','PPSR','PPTR','PHPM']
cand = [k for k in pkeys if k not in agg and np.nanstd(cols[k][m]) > 1e-4]
X = np.column_stack([cols[k][m] for k in cand])
def fit(target, extra=[]):
    Xe = np.column_stack([X] + [cols[k][m] for k in extra] + [np.ones(m.sum())])
    y = cols[target][m]; c, *_ = np.linalg.lstsq(Xe, y, rcond=None)
    r = y - Xe @ c
    names = cand + extra + ['const']
    print(f'\n{target} ~ sub-rails: rms residual {np.sqrt(np.mean(r**2)):.3f} W (target mean {y.mean():.2f}, std {y.std():.2f})')
    print('   ' + '  '.join(f'{n}:{v:+.2f}' for n, v in zip(names, c) if abs(v) > 0.08))
for tg in ['PPMR','PPSR','PPTR','PHPC','PMVC']:
    fit(tg)
# simple identities
def chk(lhs, rhs):
    a = cols[lhs][m]; b = sum(cols[k][m] for k in rhs); d = a - b
    print(f'  {lhs} - ({"+".join(rhs)}): mean {d.mean():+.3f} W, std {d.std():.3f} W, max|d| {np.abs(d).max():.3f}')
print('\nidentity checks (1 Hz):')
chk('PMVC', ['PPMR','PPSR','PPTR'])
chk('PMVC', ['PPMR','PPSR','PPTR','PHPM'])
chk('PHPC', ['PPMR','PPSR','PPTR'])
chk('PZC0', ['PZC1'])
chk('PDTR', ['PMVC'])
# lagged relation PZC0 vs PHPC
for L in range(0, 3):
    a = cols['PZC0'][m][L:]; b = cols['PHPC'][m][:len(cols['PHPC'][m]) - L]
    print(f'  corr(PZC0[t], PHPC[t-{L}]) = {np.corrcoef(a, b)[0,1]:.4f}')
