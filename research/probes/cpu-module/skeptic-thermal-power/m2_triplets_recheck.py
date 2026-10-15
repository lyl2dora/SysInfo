#!/usr/bin/env python3
"""m2_triplets_recheck.py — 复核 M2 温度键「三元组」结论（独立实现）：
1) 对 Tp0*/Tp1* 所有键两两求差，报告差值标准差 < 0.05 的键对（恒定偏移）与偏移量；
2) x2（尖峰）相对 x1 的差值分布；
3) 纯 CPU 负载秒里 TCMb 与 max(x1)、max(x2)、max(x0) 的差；GPU 负载秒里同样比较。
用法：m2_triplets_recheck.py a.csv [b.csv ...]
"""
import csv, sys, math, itertools, statistics as st
H = None; data = {}
for fn in sys.argv[1:]:
    rows = list(csv.reader(open(fn))); h = rows[0]
    for r in rows[1:]:
        for i, k in enumerate(h):
            if len(k) == 4 and k[0] == 'T' or k in ('phase', 'util_c0', 'util_c1', 'util_c2', 'EM:GPU Energy'):
                try: v = float(r[i])
                except: v = r[i]
                data.setdefault(k, []).append(v)
N = len(data['phase'])
tp = sorted(k for k in data if k[:3] in ('Tp0', 'Tp1', 'Tp2', 'Te0'))
pairs = []
for a, b in itertools.combinations(tp, 2):
    d = [x - y for x, y in zip(data[a], data[b])]
    s = st.pstdev(d)
    if s < 0.05: pairs.append((a, b, st.mean(d), s))
print(f"N={N}；Tp/Te 键 {len(tp)} 个；差值 σ<0.05 的键对 {len(pairs)}：")
for a, b, m, s in pairs: print(f"   {a}-{b}: 偏移 {m:+.3f} σ={s:.4f}")
# 按三元组分组：同前三字符、按 SMC 键序号连续 → 手工给出 Tp0 族
grp = {}
for a, b, m, s in pairs: grp.setdefault(a, []).append((b, m))
x0x1 = [(a, b if m < 0 else a) for a, lst in grp.items() for b, m in lst]
# x2 候选：Tp/Te 中不在任何恒定偏移对中的键
paired = {a for a, b, m, s in pairs} | {b for a, b, m, s in pairs}
lone = [k for k in tp if k not in paired]
print('无恒定偏移伙伴的键（x2 候选及其他）：', ' '.join(lone))
# x1 = 每对中值较大者
x1 = sorted({(b if m < 0 else a) for a, b, m, s in pairs}); x0 = sorted({(a if m < 0 else b) for a, b, m, s in pairs})
tp_lone = [k for k in lone if k[:3] in ('Tp0', 'Tp1')]
cpu = [i for i in range(N) if isinstance(data['EM:GPU Energy'][i], float) and data['EM:GPU Energy'][i] < 1 and (data['util_c1'][i] > 0.9 or data['util_c2'][i] > 0.9)]
gpu = [i for i in range(N) if isinstance(data['EM:GPU Energy'][i], float) and data['EM:GPU Energy'][i] > 20]
def rep(idx, lab):
    if not idx: print(f"{lab}: 无样本"); return
    for nm, ks in (('max x0', x0), ('max x1', x1), ('max 孤立 Tp0/Tp1 (x2?)', tp_lone)):
        d = [data['TCMb'][i] - max(data[k][i] for k in ks) for i in idx]
        print(f"{lab} n={len(idx)}: TCMb − {nm}: 中位 {st.median(d):+.2f}，范围 {min(d):+.2f}..{max(d):+.2f}")
    d = [data['TCMz'][i] - max(data[k][i] for k in tp_lone) for i in idx]
    print(f"{lab}: TCMz − max(x2?): 中位 {st.median(d):+.2f}，范围 {min(d):+.2f}..{max(d):+.2f}")
    print(f"{lab}: 均值 max x0={st.mean(max(data[k][i] for k in x0) for i in idx):.1f} x1={st.mean(max(data[k][i] for k in x1) for i in idx):.1f} x2?={st.mean(max(data[k][i] for k in tp_lone) for i in idx):.1f} TCMb={st.mean(data['TCMb'][i] for i in idx):.1f}")
rep(cpu, 'P 簇满载秒')
rep(gpu, 'GPU>20W 秒')
# x2 − x1 分布（同簇最大值）
d = [max(data[k][i] for k in tp_lone) - max(data[k][i] for k in x1) for i in range(N)]
print(f"全体秒 max(x2?) − max(x1): 中位 {st.median(d):+.2f} 分位 5%/95% {sorted(d)[int(.05*N)]:+.2f}/{sorted(d)[int(.95*N)]:+.2f}")
