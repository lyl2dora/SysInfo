#!/usr/bin/env python3
# analyze.py <bindir> <tag> <freq_table_MHz,逗号分隔，对应 P1..Pn>
# 读 gpu_watch 的 gw_<tag>.csv / _pmgr.txt / _temps.csv 与 phases_<tag>.log，输出：
#   1. 各负载段的均值（每段去掉首尾各 3 s）；
#   2. PMGR 窗口对账（GPU / ANE / AVE 批次 vs AGX 积分、coalition 槽位 41 / 39 积分）；
#   3. 各读取分段的真实节奏开销（中位数、均值、p95，ms/次）；
#   4. Tg / Ta 键的占位值与负载响应。
import csv, math, re, statistics, sys

d, tag, table = sys.argv[1], sys.argv[2], [float(x) for x in sys.argv[3].split(",")]
rows = list(csv.DictReader(open(f"{d}/gw_{tag}.csv")))
for r in rows:
    for k, v in list(r.items()):
        if k in ("gpuph_states", "pwrctrl_top"):
            continue
        try:
            r[k] = float(v)
        except ValueError:
            r[k] = math.nan
phases, batch = [], []
for line in open(f"{d}/phases_{tag}.log"):
    p = line.split()
    if p[0] == "PHASE_START":
        phases.append([p[1], float(p[2]), None])
    elif p[0] == "PHASE_END":
        for ph in phases:
            if ph[0] == p[1] and ph[2] is None:
                ph[2] = float(p[2])
    elif p[0].startswith("BATCH"):
        batch.append(float(p[1]))

def freq_of(states):
    """由「P1:6 P13:90」形式的驻留百分比估算活跃期间的平均频率（MHz）。"""
    tot = w = 0.0
    for m in re.finditer(r"P(\d+):(\d+)", states or ""):
        k, pct = int(m.group(1)), float(m.group(2))
        if 1 <= k <= len(table):
            w += table[k - 1] * pct
            tot += pct
    return w / tot if tot else math.nan

for r in rows:
    r["freq"] = freq_of(r["gpuph_states"])
    r["ut"] = r["ut_sum"] / r["ut_count"] if r["ut_count"] and r["ut_count"] > 0 else math.nan
    r["tavg"] = r["temp_avg_sum"] / r["temp_avg_count"] if r["temp_avg_count"] and r["temp_avg_count"] > 0 else math.nan

def mean(xs):
    xs = [x for x in xs if isinstance(x, float) and not math.isnan(x)]
    return statistics.fmean(xs) if xs else math.nan

def seg(t0, t1):
    return [r for r in rows if t0 + 3 <= r["epoch"] <= t1 - 3]

cols = [("gpuph_active", "活跃", 100, "%.1f"), ("freq", "MHz", 1, "%.0f"), ("gpu_w", "W", 1, "%.2f"),
        ("coal_gpu_busy", "coalGPU", 100, "%.1f"), ("coal_gpu_w", "coalW", 1, "%.2f"), ("bst_active", "BST", 100, "%.0f"),
        ("sw_active", "SW", 100, "%.0f"), ("cltm_limited", "CLTM", 100, "%.0f"), ("pzr_zoned", "PZR", 100, "%.0f"),
        ("dvdh_mean", "DVDH", 1, "%.0f"), ("ppm_mean", "PPM", 1, "%.0f"), ("ut", "UT", 1, "%.0f"),
        ("tavg", "Tagx", 1, "%.1f"), ("temp_max", "TagxMax", 1, "%.0f"), ("tg_max", "Tg", 1, "%.1f"), ("ta_max", "Ta", 1, "%.1f"),
        ("irq_ave", "ave/s", 1, "%.0f"), ("irq_avd", "avd/s", 1, "%.0f"), ("irq_apr", "apr/s", 1, "%.0f"), ("irq_ane", "ane/s", 1, "%.0f"),
        ("pmp_agx", "bwAGX", 1, "%.2f"), ("pmp_ane", "bwANE", 1, "%.2f"), ("pmp_ave", "bwAVE", 1, "%.2f"), ("pmp_avd", "bwAVD", 1, "%.2f"),
        ("ni_ane", "niANE", 1, "%.2f"), ("ni_ave", "niAVE", 1, "%.2f"),
        ("ane_ps", "ANEon", 100, "%.0f"), ("coal_ane_busy", "coalANE", 100, "%.1f"), ("coal_ane_w", "aneW", 1, "%.2f"),
        ("dev_util", "DevU", 1, "%.0f"), ("gpu_inuse_mb", "inuseMB", 1, "%.0f")]
print(f"# {tag}: 各段均值（去首尾 3 s）")
print("段 | " + " | ".join(c[1] for c in cols) + " | 主要档位 | PWRCTRL")
idle_spans = []
if phases:
    idle_spans.append(("idle_pre", phases[0][1] - 50, phases[0][1] - 5))
spans = [(p[0], p[1], p[2]) for p in phases if p[2]] + idle_spans
for name, t0, t1 in spans:
    s = seg(t0, t1)
    if not s:
        continue
    vals = [(c[3] % (mean([r[c[0]] for r in s]) * c[2])) for c in cols]
    st = statistics.mode([r["gpuph_states"] for r in s]) if s else ""
    pw = statistics.mode([r["pwrctrl_top"].split(":")[0] for r in s if r["pwrctrl_top"]] or [""])
    print(f"{name} | " + " | ".join(vals) + f" | {st} | {pw}")

# ANE 关断滞后：ANE 段结束后 ane_ps 保持 1 的秒数
for name, t0, t1 in spans:
    if name.startswith("ane"):
        after = [r for r in rows if r["epoch"] > t1]
        lag = next((r["epoch"] - t1 for r in after if r["ane_ps"] == 0), math.nan)
        before = [r for r in rows if t0 <= r["epoch"] <= t0 + 10]
        on = next((r["epoch"] - t0 for r in before if r["ane_ps"] >= 1), math.nan)
        print(f"{name}: ANE 上电滞后 {on:.1f} s，关断滞后 {lag:.1f} s")

# 2. PMGR 窗口对账
print(f"\n# {tag}: PMGR 窗口对账")
changes = []
cur = None
for line in open(f"{d}/gw_{tag}_pmgr.txt"):
    if line.startswith("==="):
        p = line.split()
        if p[2] == "CHANGE":
            n = int(p[3].split("=")[1])
            deltas = dict((m.group(1), int(m.group(2))) for m in re.finditer(r" (\S+?)([+-]\d+)", line[line.index("nchanged"):]))
            changes.append((float(p[1]), n, deltas))
big = [c for c in changes if c[1] >= 3]
for i, (t, n, deltas) in enumerate(big):
    # 批次在 t 发布，覆盖 [t-1800, t]
    w0, w1 = t - 1800, t
    win = [r for r in rows if w0 < r["epoch"] <= w1]
    cover = len(win)
    def integ(k):
        return sum((r[k] if not math.isnan(r[k]) else 0) * r["dt"] for r in win)
    agx, c41, c39 = integ("gpu_w"), integ("coal_gpu_w"), integ("coal_ane_w")
    gpu_b = next((v for k, v in deltas.items() if k in ("GPU", "GPU0")), math.nan) / 1000
    ane_b = next((v for k, v in deltas.items() if k in ("ANE", "ANE0")), math.nan) / 1000
    ave_b = next((v for k, v in deltas.items() if k in ("AVE", "AVE0")), math.nan) / 1000
    print(f"batch@{t:.0f} 覆盖 {cover} s：GPU 批次 {gpu_b:.1f} J，AGX 积分 {agx:.1f} J（比 {agx / gpu_b if gpu_b else math.nan:.3f}），"
          f"coalition 槽位 41 积分 {c41:.1f} J（比 {c41 / gpu_b if gpu_b else math.nan:.3f}）；"
          f"ANE 批次 {ane_b:.1f} J，槽位 39 积分 {c39:.1f} J（比 {c39 / ane_b if ane_b else math.nan:.3f}）；AVE 批次 {ave_b:.1f} J"
          f"；其余变化通道 {sorted(k for k in deltas if k not in ('GPU','GPU0','ANE','ANE0','AVE','AVE0'))}")

# 3. 开销
print(f"\n# {tag}: 真实节奏开销（ms/次，1 Hz，全程）")
for k in ["cpu_gpuph_ms", "cpu_gpuext_ms", "cpu_energy_ms", "cpu_pmgr_ms", "cpu_irq_ms", "cpu_pmp_ms", "cpu_smc_ms", "cpu_coal_ms", "cpu_ioreg_ms"]:
    xs = sorted(r[k] for r in rows if not math.isnan(r[k]))
    if xs:
        print(f"{k}: 中位 {statistics.median(xs):.3f}，均值 {statistics.fmean(xs):.3f}，p95 {xs[int(len(xs) * 0.95)]:.3f}")

# 4. Tg / Ta
print(f"\n# {tag}: Tg / Ta 键")
trows = list(csv.reader(open(f"{d}/gw_{tag}_temps.csv")))
hdr, data = trows[0], [[float(x) for x in r] for r in trows[1:] if len(r) == len(trows[0])]
full = next((p for p in phases if p[0] == "gpu_full"), None)
ane = next((p for p in phases if p[0] == "ane4"), None)
def colmean(i, t0, t1):
    xs = [r[i] for r in data if t0 <= r[0] <= t1 and not math.isnan(r[i])]
    return statistics.fmean(xs) if xs else math.nan
for i, k in enumerate(hdr[1:], 1):
    vals = [r[i] for r in data if not math.isnan(r[i])]
    if not vals:
        continue
    distinct = len(set(round(v, 3) for v in vals))
    mode = statistics.mode(round(v, 3) for v in vals)
    mode_frac = sum(1 for v in vals if round(v, 3) == mode) / len(vals)
    base = colmean(i, phases[0][1] - 50, phases[0][1] - 5) if phases else math.nan
    g = colmean(i, full[2] - 10, full[2]) if full else math.nan
    a = colmean(i, ane[2] - 10, ane[2]) if ane else math.nan
    print(f"{k}: min {min(vals):.2f} max {max(vals):.2f} 取值数 {distinct} 众数 {mode}({mode_frac:.0%}) 空闲 {base:.1f} GPU 段末 {g:.1f} ANE 段末 {a:.1f}")
