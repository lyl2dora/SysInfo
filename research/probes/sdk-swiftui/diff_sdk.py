#!/usr/bin/env python3
"""Diff parsed declarations of the 26.5 SDK (CommandLineTools) vs the 27.0 SDK (Xcode 27).
Emits:
  diff_added.txt    decls present in 27 SDK but not 26.5 (grouped: eff intro 27.0 vs older/back-deployed)
  diff_removed.txt  decls present in 26.5 but not in 27
  diff_availability.txt  same decl, macOS availability/deprecation changed
"""
import json
import re
from collections import Counter, defaultdict

MODS = ("SwiftUI", "SwiftUICore", "Swift", "Foundation", "CoreFoundation", "CoreGraphics",
        "_Concurrency", "Combine", "UniformTypeIdentifiers", "Observation", "Charts", "AppKit",
        "Accessibility", "CoreData", "CoreMedia", "CoreTransferable", "DataDetection",
        "DeveloperToolsSupport", "Dispatch", "os", "OSLog", "simd", "Spatial", "Symbols",
        "_StringProcessing", "CoreText", "QuartzCore", "Darwin", "ObjectiveC")
MOD_RE = re.compile(r"\b(?:" + "|".join(MODS) + r")(?:::|\.)(?=[A-Za-z_`])")


def norm(text):
    t = text.replace("::", ".")
    # cut body
    depth = 0
    out = ""
    for c in t:
        if c == "{":
            break
        out += c
    t = out
    for _ in range(3):
        t = MOD_RE.sub("", t)
    t = t.replace("ContentBuilder", "ViewBuilder")
    t = re.sub(r",\s*~(Swift\.)?(Sendable|Copyable|Escapable|BitwiseCopyable)\b", "", t)
    t = re.sub(r":\s*~(Swift\.)?(Sendable|Copyable|Escapable|BitwiseCopyable)\s*,\s*", ": ", t)
    t = re.sub(r":\s*~(Swift\.)?(Sendable|Copyable|Escapable|BitwiseCopyable)\b\s*", " ", t)
    t = re.sub(r"@_opaqueReturnTypeOf\(\"[^\"]*\", \d+\) __(<[^>]*>)?", "OPAQUE", t)
    t = re.sub(r"@(MainActor|preconcurrency|Sendable|_inheritActorContext|_implicitSelfCapture|isolated\(any\)|_disfavoredOverload)\s*", "", t)
    t = re.sub(r"\b(sending|nonisolated\(nonsending\)|nonisolated|consuming|borrowing|__owned|__shared)\s+", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def load(v, m):
    recs = []
    try:
        for l in open(f"v{v}/{m}.jsonl"):
            r = json.loads(l)
            r["key"] = (norm(r["scope"]), r["kw"], norm(r["decl"]))
            if r.get("nonpublic"):
                continue
            recs.append(r)
    except FileNotFoundError:
        pass
    return recs


def fmt_av(r):
    o = r["own"]
    e = r["eff"]
    s = f"own={o['intro']}"
    if o["deprecated"]:
        s += f" dep={o['deprecated']}"
    if o["obsoleted"]:
        s += f" obs={o['obsoleted']}"
    if o["unavailable"]:
        s += " UNAVAIL"
    s += f" | eff={e['intro']}"
    if e.get("unavailable"):
        s += " effUNAVAIL"
    return s


def main():
    added_out = open("diff_added.txt", "w")
    removed_out = open("diff_removed.txt", "w")
    avail_out = open("diff_availability.txt", "w")
    summary = []
    # SwiftUI and SwiftUICore share symbols (types moved between them); diff the union.
    groups = {"SwiftUI+SwiftUICore": ["SwiftUI", "SwiftUICore"], "Charts": ["Charts"], "Observation": ["Observation"]}
    for g, mods in groups.items():
        def dedupe(lst):
            seen=set(); out=[]
            for r in lst:
                if r["key"] in seen: continue
                seen.add(r["key"]); out.append(r)
            return out
        a = dedupe([r for m in mods for r in load(26, m)])
        b = dedupe([r for m in mods for r in load(27, m)])
        ca = Counter(r["key"] for r in a)
        cb = Counter(r["key"] for r in b)
        amap = defaultdict(list)
        for r in a:
            amap[r["key"]].append(r)
        seen = Counter()
        added = []
        for r in b:
            seen[r["key"]] += 1
            if seen[r["key"]] > ca.get(r["key"], 0):
                added.append(r)
        seen = Counter()
        removed = []
        for r in a:
            seen[r["key"]] += 1
            if seen[r["key"]] > cb.get(r["key"], 0):
                removed.append(r)
        # availability changes on unique matches
        bmap = defaultdict(list)
        for r in b:
            bmap[r["key"]].append(r)
        chg = []
        for k, lst in bmap.items():
            if len(lst) == 1 and len(amap.get(k, [])) == 1:
                x, y = amap[k][0], lst[0]
                if (x["own"]["intro"], x["own"]["deprecated"], x["own"]["obsoleted"], x["own"]["unavailable"], x["eff"].get("unavailable")) != \
                   (y["own"]["intro"], y["own"]["deprecated"], y["own"]["obsoleted"], y["own"]["unavailable"], y["eff"].get("unavailable")):
                    chg.append((x, y))
        # only macOS-available
        def mac_ok(r):
            return not r["eff"].get("unavailable")
        added_mac = [r for r in added if mac_ok(r)]
        new27 = [r for r in added_mac if r["eff"]["intro"] == "27.0"]
        older = [r for r in added_mac if r["eff"]["intro"] != "27.0"]
        summary.append(f"{g}: 26.5 decls={len(a)} 27 decls={len(b)} added={len(added)} (macOS-available {len(added_mac)}: eff27={len(new27)}, older-availability={len(older)}) removed={len(removed)} availability-changed={len(chg)}")
        added_out.write(f"\n######## {g}: ADDED with effective macOS availability < 27.0 or unspecified (back-deployed / newly public) [{len(older)}]\n")
        for r in older:
            added_out.write(f"{r['module']}:L{r['line']} [{r['scope']}] {r['kw']} {r['decl'][:230]}\n      {fmt_av(r)} :: {' '.join(r['own']['raw'])[:160]}\n")
        added_out.write(f"\n######## {g}: ADDED with effective macOS 27.0 [{len(new27)}]\n")
        for r in new27:
            added_out.write(f"{r['module']}:L{r['line']} [{r['scope']}] {r['kw']} {r['decl'][:230]}\n")
        added_out.write(f"\n######## {g}: ADDED but macOS-unavailable [{len(added) - len(added_mac)}]\n")
        for r in added:
            if not mac_ok(r):
                added_out.write(f"{r['module']}:L{r['line']} [{r['scope']}] {r['kw']} {r['decl'][:160]}\n")
        removed_out.write(f"\n######## {g}: REMOVED (in 26.5, not in 27) [{len(removed)}]\n")
        for r in removed:
            removed_out.write(f"{r['module']}:L{r['line']}(26.5) [{r['scope']}] {r['kw']} {r['decl'][:230]}\n      {fmt_av(r)}\n")
        avail_out.write(f"\n######## {g}: AVAILABILITY CHANGED [{len(chg)}]\n")
        for x, y in chg:
            avail_out.write(f"{y['module']}:L{y['line']} [{y['scope']}] {y['kw']} {y['decl'][:200]}\n      26.5: {fmt_av(x)} :: {' '.join(x['own']['raw'])[:200]}\n      27.0: {fmt_av(y)} :: {' '.join(y['own']['raw'])[:200]}\n")
    open("diff_summary.txt", "w").write("\n".join(summary) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
