# match.py - match SMC P* key window integrals against single PMGR Energy Model channel deltas (18:08:29 -> 18:38:29)
import numpy as np, re, csv, time
exec(open('analyze.py').read().split('# ---------- phases ----------')[0].replace("print(","(lambda *a, **k: None)("))
pm = {k: v for k, v in dP.items()}
print('SMC key integral (J) -> closest single Energy Model channel delta (J) [rel diff]; only keys with integral > 5 J')
for k in sorted(pkeys, key=lambda k: -ints[k]):
    e = ints[k]
    if e < 5: continue
    best = sorted(pm.items(), key=lambda kv: abs(kv[1] - e))[:2]
    s = '  '.join(f'{n}={v:.1f} ({(e - v) / v * 100 if v else np.inf:+.2f}%)' for n, v in best)
    print(f'  {k}: {e:9.1f} J  -> {s}')
# group sums
def S(pat): return sum(v for n, v in pm.items() if re.fullmatch(pat, n))
print('\nPMGR structure checks:')
print('  CPU Energy', pm['CPU Energy'], '= PCPU+MCPU0+MCPU1', pm['PCPU'] + pm['MCPU0'] + pm['MCPU1'])
print('  PCPU', pm['PCPU'], ' sum PACC_i', S(r'PACC_\d'), ' sum PCPUi_SRAM', S(r'PCPU\d_SRAM'), ' PACC+SRAM', S(r'PACC_\d') + S(r'PCPU\d_SRAM'))
print('  MCPU0', pm['MCPU0'], ' sum MCPU0_i', S(r'MCPU0_\d'), ' +SRAM', S(r'MCPU0_\d') + S(r'MCPU0_\d_SRAM'))
print('  MCPU1', pm['MCPU1'], ' sum MCPU1_i', S(r'MCPU1_\d'), ' +SRAM', S(r'MCPU1_\d') + S(r'MCPU1_\d_SRAM'))
print('  DTL sum', S(r'.*DTL.*'), ' PCPM', pm['PCPM'], 'PCPM_SRAM', pm.get('PCPM_SRAM'), 'MCPM0', pm['MCPM0'], 'MCPM0_SRAM', pm.get('MCPM0_SRAM'), 'MCPM1', pm['MCPM1'], 'MCPM1_SRAM', pm.get('MCPM1_SRAM'))
print('  DTL groups:', {g: round(S(g + r'DTL.*'), 1) for g in ['MCPU0', 'MCPU1', 'PCPU']})
