#!/usr/bin/env python3
"""List declarations carrying macOS 27 introduced/deprecated availability.
Usage: decls27.py <swiftinterface-or-header> [...]
Prints: line: <availability> || <decl>  (decl = next non-attribute line, with
enclosing type context for members)."""
import re, sys

intro_s = re.compile(r"@available\((?:[^)]*\bmacOS (?:27(?:\.0)?)\b|macOS,\s*introduced:\s*27|anyAppleOS 27)")
depr_s = re.compile(r"@available\((?:macOS|\*)[^)]*deprecated(?::\s*27(?:\.0)?)?")
depr27_s = re.compile(r"@available\((?:macOS|anyAppleOS)[^)]*deprecated:\s*27")
intro_h = re.compile(r"(?:macos|anyappleos)\(\s*27(?:\.0)?\s*\)|MAC_OS_VERSION_27_0")
depr_h = re.compile(r"macos\(\s*[0-9.]+\s*,\s*27(?:\.0)?\s*\)")
unavail_mac = re.compile(r"@available\(macOS, unavailable")

def ctx_stack_update(stack, line, depth):
    return

for path in sys.argv[1:]:
    lines = open(path, errors="ignore").read().splitlines()
    is_swift = path.endswith(".swiftinterface")
    depth = 0
    ctx = []  # (depth, name)
    for i, l in enumerate(lines):
        s = l.strip()
        hit = None
        if is_swift:
            if depr27_s.search(s):
                hit = "DEPR27"
            elif intro_s.search(s):
                hit = "NEW27"
        else:
            if depr_h.search(s):
                hit = "DEPR27"
            elif intro_h.search(s):
                hit = "NEW27"
        if hit:
            # find declaration
            if is_swift:
                j = i + 1
                while j < len(lines) and lines[j].strip().startswith("@") and not re.match(r"\s*@\w+.*\b(func|var|let|init|case|class|struct|enum|protocol|typealias|extension|actor|macro|subscript)\b", lines[j]):
                    j += 1
                decl = lines[j].strip() if j < len(lines) else ""
                # skip if macOS explicitly unavailable in the attribute block
                blk = " ".join(x.strip() for x in lines[max(0, i-6):j])
                macun = "@available(macOS, unavailable" in " ".join(x.strip() for x in lines[i:j])
            else:
                # header: decl is this line (or previous lines up to ';' / '{')
                k = i
                while k > 0 and not re.search(r"[;{}]\s*$", lines[k-1]) and not lines[k-1].strip().startswith(("//", "#")) and i - k < 6:
                    k -= 1
                decl = " ".join(x.strip() for x in lines[k:i+1])
                macun = False
            c = ".".join(n for d, n in ctx)
            print(f"{hit}\t{i+1}\t{'[macOS-unavail] ' if macun else ''}{('['+c+'] ') if c else ''}{decl[:220]}\t|| {s[:160]}")
        # crude context tracking for swift
        if is_swift:
            m = re.match(r"\s*(?:@[\w:.()\"\s,]+\s)?(?:public |open |final |@\w+ |nonisolated |indirect )*(?:class|struct|enum|protocol|extension|actor)\s+([\w.:<>]+)", l)
            opens = l.count("{"); closes = l.count("}")
            if m and opens > closes:
                ctx.append((depth, m.group(1).replace("::", ".")))
            depth += opens - closes
            while ctx and ctx[-1][0] >= depth:
                ctx.pop()
