#!/usr/bin/env python3
# probe B：从 log stream 的记录里统计每个 kind 的刷新（按原因）、实际执行的 timeline 请求和间隔。
# 用法：b_analyze.py <stream.log> [起始 HH:MM] [结束 HH:MM] [bundle 片段，默认 sysinfo.dev.probe]
import re, sys, collections
from datetime import datetime

path = sys.argv[1]
start = sys.argv[2] if len(sys.argv) > 2 else "00:00"
end = sys.argv[3] if len(sys.argv) > 3 else "99:99"
bundle = sys.argv[4] if len(sys.argv) > 4 else "sysinfo.dev.probe"

rec = re.compile(r"^(\S+ \S+) .*record reload: \[zone\.lyl\.(\S+?)::\S+:(Probe\w+)\] = (\w+)")
sched = re.compile(r"^(\S+ \S+) .*\[zone\.lyl\.(\S+?)::\S+:(Probe\w+)\] Scheduling reload with configuration: \[(.*)\]$")
succ = re.compile(r"^(\S+ \S+) .*\[zone\.lyl\.(\S+?)::\S+:(Probe\w+)\] Reload success")
ignore = re.compile(r"^(\S+ \S+) .*\[zone\.lyl\.(\S+?)::\S+:(Probe\w+)\] (Ignoring.*?)(; |$)")
exempt = re.compile(r"^(\S+ \S+) .*\[zone\.lyl\.(\S+?)::\S+:(Probe\w+)\]>\.\w+ overridden for budget exempt reason: (\w+)")

reasons = collections.Counter()
budget = collections.Counter()
ignored = collections.Counter()
exempts = collections.Counter()
success = collections.defaultdict(list)

def inwin(ts):
    hm = ts.split()[1][:5]
    return start <= hm <= end

for line in open(path, errors="replace"):
    for rx, kind in ((rec, "rec"), (sched, "sched"), (succ, "succ"), (ignore, "ign"), (exempt, "ex")):
        m = rx.match(line)
        if not m or bundle not in m.group(2) or not inwin(m.group(1)):
            continue
        ts, w = m.group(1), m.group(3)
        if kind == "rec":
            reasons[(w, m.group(4))] += 1
        elif kind == "sched":
            cfg = m.group(4)
            b = "free" if "-free-" in cfg else ("budgeted" if "-budgeted-" in cfg else "?")
            r = cfg.split("(")[0].split("-")[0]
            budget[(w, r, b)] += 1
        elif kind == "succ":
            success[w].append(datetime.strptime(ts[:19], "%Y-%m-%d %H:%M:%S"))
        elif kind == "ign":
            ignored[(w, m.group(4)[:90])] += 1
        else:
            exempts[(w, m.group(4))] += 1
        break

print(f"窗口 {start}–{end}，{bundle}")
print("\n## 记录的刷新原因")
for k, v in sorted(reasons.items()):
    print(f"  {k[0]:11} {k[1]:22} {v}")
print("\n## 排期（原因 / 是否计预算）")
for k, v in sorted(budget.items()):
    print(f"  {k[0]:11} {k[1]:22} {k[2]:9} {v}")
print("\n## 豁免")
for k, v in sorted(exempts.items()):
    print(f"  {k[0]:11} {k[1]:22} {v}")
print("\n## 被忽略")
for k, v in sorted(ignored.items()):
    print(f"  {k[0]:11} {v:4}  {k[1]}")
print("\n## 实际执行（Reload success）")
for w, ts in sorted(success.items()):
    gaps = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
    big = [g for g in gaps if g > 90]
    print(f"  {w}: {len(ts)} 次，首 {ts[0]:%H:%M:%S} 末 {ts[-1]:%H:%M:%S}；间隔 >90 s 的 {len(big)} 次，最长 {max(gaps or [0]):.0f} s")
