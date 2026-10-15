#!/usr/bin/env python3
"""phase_rise.py — 按阶段类型汇总 tp_watch CSV：同名负载阶段（重复脉冲）的升幅取平均。
升幅 = 负载阶段末 N 秒均值 − 紧邻前一 idle 阶段末 N 秒均值。输出每个键在每类负载下的平均升幅（°C 或 W）与簇占用增量。
用法：phase_rise.py a.csv [b.csv ...] [--prefix T] [--tail 3] [--sort 相位名] [--min 1.0] [--keys K1,K2]
"""
import csv, math, argparse
from collections import defaultdict
ap = argparse.ArgumentParser(); ap.add_argument('csv', nargs='+'); ap.add_argument('--prefix', default='T'); ap.add_argument('--tail', type=int, default=3)
ap.add_argument('--sort', default=None); ap.add_argument('--min', type=float, default=1.0); ap.add_argument('--keys', default=None)
a = ap.parse_args()
acc = defaultdict(lambda: defaultdict(list)); order = []
for fn in a.csv:
    rows = list(csv.reader(open(fn))); hdr = rows[0]
    phases = []
    for r in rows[1:]:
        if not phases or phases[-1][0] != r[1]: phases.append((r[1], []))
        phases[-1][1].append(r)
    def tm(rs, i):
        v = []
        for r in rs[-a.tail:]:
            try:
                x = float(r[i])
                if not math.isnan(x): v.append(x)
            except: pass
        return sum(v) / len(v) if v else None
    for j in range(1, len(phases)):
        name, rs = phases[j]
        if name == 'idle': continue
        if name not in order: order.append(name)
        base = phases[j - 1][1]
        for i, h in enumerate(hdr):
            if i < 2: continue
            b, l = tm(base, i), tm(rs, i)
            if b is None or l is None: continue
            acc[h][name].append(l - b)
            acc[h][name + '@abs'].append(l)
cols = order
pref = tuple(a.prefix.split(','))
print('phase types:', cols, ' (值 = 平均升幅；括号 = 负载末绝对值)')
for h in [h for h in acc if h.startswith('util_c') or h.startswith('EM:')]:
    print(f"  {h:12s} " + ' '.join(f"{c}={sum(acc[h][c])/len(acc[h][c]):+.2f}" for c in cols if acc[h][c]))
keys = [h for h in acc if h.startswith(pref)] if not a.keys else a.keys.split(',')
def m(h, c):
    v = acc[h].get(c) or []; return sum(v) / len(v) if v else float('nan')
sk = a.sort or cols[-1]
keys = [h for h in keys if max(abs(m(h, c)) for c in cols) >= a.min]
keys.sort(key=lambda h: -m(h, sk))
for h in keys:
    print(f"  {h:5s} " + ' '.join(f"{c}={m(h,c):+6.2f}({m(h,c+'@abs'):.1f})" for c in cols))
