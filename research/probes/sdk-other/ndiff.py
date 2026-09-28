#!/usr/bin/env python3
"""Normalized API diff between CLT macOS 26.5 SDK and Xcode macOS 27.0 SDK.
Swift 6.4 interfaces in the 27 SDK use module selectors (Swift::Int) while 26.5
uses dotted qualification (Swift.Int); strip both so the diff shows real API
changes only. Headers are diffed as-is (whitespace-insensitive).
Usage: ndiff.py Name [Name...] -> ndiffs/<Name>.diff, prints +/- counts
"""
import os, re, sys, difflib, glob

X = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
C = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ndiffs")
os.makedirs(OUT, exist_ok=True)

def swift_lines(path, modname):
    if not path or not os.path.exists(path):
        return []
    t = open(path, errors="ignore").read().splitlines()
    t = [l for l in t if not l.lstrip().startswith("//") and l.strip()]
    mods = {modname, "Swift", "_Concurrency", "_StringProcessing", "_SwiftConcurrencyShims", "Foundation", "Darwin", "os", "Dispatch", "ObjectiveC", "CoreFoundation", "Combine", "SwiftUI", "SwiftUICore", "AppKit", "CoreGraphics", "Observation", "Synchronization", "System", "Network", "Metal", "OSLog", "AppIntents", "WidgetKit", "Accessibility", "CoreHID", "IOKit", "StateReporting", "CoreTransferable", "UniformTypeIdentifiers", "CoreData", "Charts", "QuartzCore", "CoreText", "CoreImage", "_AppIntents_SwiftUI", "_AppIntents_AppKit", "DeveloperToolsSupport", "Security", "CoreLocation", "Intents", "MetricKit"}
    for l in t:
        m = re.match(r"\s*(?:@_exported\s+)?import\s+(?:\w+\s+)?([\w.]+)", l)
        if m:
            mods.add(m.group(1).split(".")[0])
    sel = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*::")
    dot = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, mods), key=len, reverse=True)) + r")\.(?=[A-Za-z_`(])")
    out = []
    for l in t:
        l = sel.sub("", l)
        l = dot.sub("", l)
        l = re.sub(r"\s+", " ", l).strip()
        m = re.match(r"^@available\(([^)]*)\)$", l)
        if m and "," in m.group(1) and not re.search(r"unavailable|deprecated|introduced|renamed|message|obsoleted", m.group(1)):
            items = sorted(x.strip() for x in m.group(1).split(","))
            l = "@available(" + ", ".join(items) + ")"
        out.append(l)
    # sort runs of consecutive @available lines
    res, run = [], []
    for l in out:
        if l.startswith("@available("):
            run.append(l)
        else:
            res += sorted(run); run = []
            res.append(l)
    res += sorted(run)
    return res

def strip_c_comments(txt):
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
    out=[]
    for l in txt.splitlines():
        l = re.sub(r"//.*$", "", l)
        l = re.sub(r"\s+", " ", l).strip()
        if l:
            out.append(l)
    return out

def header_files(root):
    res = {}
    for d in [os.path.join(root, "Versions/A/Headers"), os.path.join(root, "Headers")]:
        if os.path.isdir(d):
            for dp, dn, fn in os.walk(d):
                for f in fn:
                    if f.endswith(".h"):
                        p = os.path.join(dp, f)
                        rel = os.path.relpath(p, d)
                        res.setdefault(rel, p)
            break
    return res

tot = []
for n in sys.argv[1:]:
    a = os.path.join(C, "System/Library/Frameworks", n + ".framework")
    b = os.path.join(X, "System/Library/Frameworks", n + ".framework")
    lines = []
    ha, hb = header_files(a), header_files(b)
    for rel in sorted(set(ha) | set(hb)):
        la = strip_c_comments(open(ha[rel], errors="ignore").read()) if rel in ha else []
        lb = strip_c_comments(open(hb[rel], errors="ignore").read()) if rel in hb else []
        if la != lb:
            lines += list(difflib.unified_diff(la, lb, "26.5/Headers/" + rel if rel in ha else "/dev/null", "27.0/Headers/" + rel if rel in hb else "/dev/null", n=1, lineterm=""))
    sa = os.path.join(a, "Modules", n + ".swiftmodule", "arm64e-apple-macos.swiftinterface")
    sb = os.path.join(b, "Modules", n + ".swiftmodule", "arm64e-apple-macos.swiftinterface")
    la, lb = swift_lines(sa, n), swift_lines(sb, n)
    if la != lb:
        lines += list(difflib.unified_diff(la, lb, "26.5/" + n + ".swiftinterface", "27.0/" + n + ".swiftinterface", n=2, lineterm=""))
    open(os.path.join(OUT, n + ".diff"), "w").write("\n".join(lines) + "\n")
    p = sum(1 for l in lines if l.startswith("+") and not l.startswith("+++"))
    m = sum(1 for l in lines if l.startswith("-") and not l.startswith("---"))
    print(f"{n:30s} +{p:<6d} -{m:<6d} headers(26.5/27): {len(ha)}/{len(hb)}")
