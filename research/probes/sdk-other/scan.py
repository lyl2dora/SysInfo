#!/usr/bin/env python3
"""Scan macOS 27 SDK for macOS-27 availability markers per framework.
Counts introduced (27) and deprecated-in-27 markers in headers (*.h) and
arm64e-apple-macos.swiftinterface files. Also computes the minimum macOS
version mentioned in any introduced availability for each framework.
Read-only. Output: scan_counts.txt, min_versions.txt
"""
import os, re, sys, collections

SDK = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
FW = os.path.join(SDK, "System/Library/Frameworks")
OUT = os.path.dirname(os.path.abspath(__file__))

# header patterns
h_intro = re.compile(r"macos\(\s*27(?:\.0)?\s*\)|MAC_OS_VERSION_27_0|__MAC_27_0|macosx\(\s*27(?:\.0)?\s*\)")
h_depr = re.compile(r"(?:API_DEPRECATED|API_DEPRECATED_WITH_REPLACEMENT|DEPRECATED)[^;]*?macos\(\s*[0-9.]+\s*,\s*27(?:\.0)?\s*\)")
h_any_ver = re.compile(r"macos\(\s*([0-9]+(?:\.[0-9]+)*)")
# swift patterns
s_intro = re.compile(r"@available\([^)]*\bmacOS (?:introduced: )?27(?:\.0)?\b")
s_intro2 = re.compile(r"@available\((?:macOS,\s*introduced:\s*|anyAppleOS )27(?:\.0)?\b")
s_depr = re.compile(r"@available\((?:macOS|\*)[^)]*deprecated(?::\s*27(?:\.0)?)?[^)]*\)")
s_depr27 = re.compile(r"@available\((?:macOS|anyAppleOS)[^)]*deprecated:\s*27(?:\.0)?\b")
s_any_ver = re.compile(r"@available\([^)]*?\bmacOS (?:introduced: )?([0-9]+(?:\.[0-9]+)*)")
s_any_ver2 = re.compile(r"@available\((?:macOS,\s*introduced:\s*|anyAppleOS )([0-9]+(?:\.[0-9]+)*)")

def vkey(v):
    return tuple(int(x) for x in v.split("."))

rows = []
for fw in sorted(os.listdir(FW)):
    if not fw.endswith(".framework"):
        continue
    root = os.path.join(FW, fw)
    hi = hd = si = sd = 0
    nh = ns = 0
    minv = None
    for dp, dn, fn in os.walk(root):
        for f in fn:
            p = os.path.join(dp, f)
            if f.endswith(".h"):
                nh += 1
                try:
                    t = open(p, errors="ignore").read()
                except Exception:
                    continue
                hi += len(h_intro.findall(t))
                hd += len(h_depr.findall(t))
                for v in h_any_ver.findall(t):
                    if minv is None or vkey(v) < vkey(minv):
                        minv = v
            elif f == "arm64e-apple-macos.swiftinterface":
                ns += 1
                t = open(p, errors="ignore").read()
                si += len(s_intro.findall(t)) + len(s_intro2.findall(t))
                sd += len(s_depr27.findall(t))
                for v in s_any_ver.findall(t) + s_any_ver2.findall(t):
                    if minv is None or vkey(v) < vkey(minv):
                        minv = v
    rows.append((fw[:-10], nh, ns, hi, hd, si, sd, minv))

with open(os.path.join(OUT, "scan_counts.txt"), "w") as o:
    o.write("framework\t#h\t#swiftif\th_intro27\th_depr27\tswift_intro27\tswift_depr27\tmin_macos_seen\n")
    for r in rows:
        o.write("\t".join(str(x) for x in r) + "\n")
print("done", len(rows))
