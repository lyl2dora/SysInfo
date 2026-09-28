# subset.py - which subsets of top-level PMGR rails (CPU Energy already contains PCPU/MCPU0/MCPU1 incl. CPM+SRAM) reproduce each SMC key integral
import itertools, numpy as np, sys
exec(open('analyze.py').read().split('# ---------- phases ----------')[0].replace("print(","(lambda *a, **k: None)("))
top = ['CPU Energy','GPU0','ANE0','DRAM0','AVE0','AMCC0','DCS0','FAB0','AFR0','DISP0','DISPEXT0','ISP0','MSR0']
vals = {k: dP[k] for k in top}
print('window', hm(W[0]), '->', hm(W[1]), {k: round(v,1) for k,v in vals.items()}, 'SUM', round(sum(vals.values()),1))
for key in ['PZC0','PZC1','PHPC','PMVC','PPMR']:
    e = ints[key]; res = []
    for r in range(1, len(top)+1):
        for c in itertools.combinations(top, r):
            s = sum(vals[x] for x in c)
            res.append((abs(s-e)/e, s, c))
    res.sort()
    print(f'\n{key} integral {e:.1f} J; best subsets (rel err):')
    for err, s, c in res[:6]:
        print(f'   {err*100:6.3f}%  {s:9.1f}  {"+".join(c)}')
