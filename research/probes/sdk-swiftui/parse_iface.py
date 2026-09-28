#!/usr/bin/env python3
"""Parse a .swiftinterface and emit one JSON record per declaration with
its own @available attributes and effective macOS availability (inherited
from enclosing type/extension scopes).

Usage: parse_iface.py <file.swiftinterface> [module-label] > out.jsonl
"""
import json
import re
import sys

DECL_KW = {
    "struct", "class", "enum", "protocol", "extension", "actor", "func",
    "var", "let", "init", "subscript", "typealias", "associatedtype", "case",
    "macro", "deinit", "operator", "precedencegroup",
}
TYPE_KW = {"struct", "class", "enum", "protocol", "extension", "actor"}
MODIFIERS = {
    "public", "open", "final", "static", "mutating", "nonmutating", "override",
    "required", "convenience", "indirect", "nonisolated", "dynamic", "lazy",
    "weak", "unowned", "prefix", "postfix", "infix", "consuming", "borrowing",
    "__consuming", "package", "optional", "isolated", "private", "fileprivate",
    "internal", "distributed", "unowned(unsafe)", "unowned(safe)", "nonisolated(unsafe)",
    "__owned", "__shared",
}


def split_attrs(s):
    """Split leading attributes (@foo, @foo(...)) off a line. Returns (attrs, rest)."""
    attrs = []
    i = 0
    n = len(s)
    while True:
        while i < n and s[i].isspace():
            i += 1
        if i < n and s[i] == "@":
            j = i + 1
            while j < n and (s[j].isalnum() or s[j] in "_." or (s[j] == ":" and j + 1 < n and s[j + 1] == ":") or (s[j] == ":" and j > 0 and s[j - 1] == ":")):
                j += 1
            if j < n and s[j] == "(":
                depth = 0
                in_str = False
                k = j
                while k < n:
                    c = s[k]
                    if in_str:
                        if c == "\\":
                            k += 2
                            continue
                        if c == '"':
                            in_str = False
                    else:
                        if c == '"':
                            in_str = True
                        elif c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                            if depth == 0:
                                break
                    k += 1
                attrs.append(s[i:k + 1])
                i = k + 1
            else:
                attrs.append(s[i:j])
                i = j
        else:
            break
    return attrs, s[i:]


def split_args(inner):
    out, cur, depth, in_str, k = [], "", 0, False, 0
    while k < len(inner):
        c = inner[k]
        if in_str:
            cur += c
            if c == "\\" and k + 1 < len(inner):
                cur += inner[k + 1]
                k += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
                cur += c
            elif c == "(":
                depth += 1
                cur += c
            elif c == ")":
                depth -= 1
                cur += c
            elif c == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
            else:
                cur += c
        k += 1
    if cur.strip():
        out.append(cur.strip())
    return out


MAC_NAMES = ("macOS",)


def parse_available(attr):
    """Return dict with macOS-relevant info from one @available attr."""
    inner = attr[len("@available("):-1]
    args = split_args(inner)
    info = {}
    if not args:
        return info
    first = args[0]
    # long form: first arg is a bare platform name or '*', followed by labelled args
    if len(args) > 1 and re.fullmatch(r"[A-Za-z_*]+", first) and (
            any(":" in a for a in args[1:]) or args[1] in ("unavailable", "deprecated", "noasync")):
        plat = first
        rel = plat in ("macOS", "anyAppleOS", "*")
        if not rel:
            return info
        for a in args[1:]:
            if a == "unavailable":
                info.setdefault("unavailable", []).append(plat)
            elif a == "deprecated":
                info["deprecated"] = info.get("deprecated") or "unconditional"
                info["dep_plat"] = plat
            elif a.startswith("introduced:"):
                info["introduced_" + plat] = a.split(":", 1)[1].strip()
            elif a.startswith("deprecated:"):
                info["deprecated"] = a.split(":", 1)[1].strip()
                info["dep_plat"] = plat
            elif a.startswith("obsoleted:"):
                info["obsoleted"] = a.split(":", 1)[1].strip()
            elif a.startswith("message:"):
                info["message"] = a.split(":", 1)[1].strip()
            elif a.startswith("renamed:"):
                info["renamed"] = a.split(":", 1)[1].strip()
        return info
    # shorthand form
    for a in args:
        m = re.fullmatch(r"([A-Za-z_]+)\s+([0-9.]+)", a)
        if m:
            info["introduced_" + m.group(1)] = m.group(2)
    return info


def mac_availability(attrs):
    """Combine own @available attrs to macOS view."""
    res = {"intro": None, "intro_src": None, "deprecated": None, "obsoleted": None,
           "unavailable": False, "message": None, "renamed": None, "raw": []}
    any_intro = None
    for a in attrs:
        if not a.startswith("@available("):
            continue
        res["raw"].append(a)
        info = parse_available(a)
        if "introduced_macOS" in info:
            res["intro"] = info["introduced_macOS"]
            res["intro_src"] = "macOS"
        if "introduced_anyAppleOS" in info:
            any_intro = info["introduced_anyAppleOS"]
        if info.get("unavailable"):
            res["unavailable"] = True
        if info.get("deprecated"):
            res["deprecated"] = info["deprecated"]
        if info.get("obsoleted"):
            res["obsoleted"] = info["obsoleted"]
        if info.get("message"):
            res["message"] = info["message"]
        if info.get("renamed"):
            res["renamed"] = info["renamed"]
    if res["intro"] is None and any_intro is not None:
        res["intro"] = any_intro
        res["intro_src"] = "anyAppleOS"
    # A shorthand attr that lists platforms but not macOS and has no '*' would make it
    # unavailable on macOS; interfaces always include '*', so treat as inherit.
    return res


def strip_modifiers(rest):
    toks = rest.split()
    i = 0
    while i < len(toks) and (toks[i] in MODIFIERS or re.fullmatch(r"(nonisolated|unowned|private|fileprivate|internal|public|package)\(.*\)", toks[i])):
        i += 1
    if i < len(toks):
        kw = toks[i]
        # 'class func' / 'class var'
        if kw == "class" and i + 1 < len(toks) and toks[i + 1] in ("func", "var", "let", "subscript"):
            return toks[i + 1], " ".join(toks[i:])
        kw = re.match(r"[A-Za-z_]+", kw)
        kw = kw.group(0) if kw else toks[i]
        return kw, " ".join(toks[i:])
    return None, ""


def brace_delta(line):
    """Return list of '{'/'}' outside strings/comments."""
    out = []
    in_str = False
    k = 0
    n = len(line)
    while k < n:
        c = line[k]
        if in_str:
            if c == "\\":
                k += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == "/" and k + 1 < n and line[k + 1] == "/":
                break
            if c == '"':
                in_str = True
            elif c in "{}":
                out.append(c)
        k += 1
    return out


def decl_name(kw, text):
    t = text.replace("::", ".")
    if kw == "extension":
        m = re.match(r"extension\s+([^\s{:]+(?:<[^>]*>)?(?:\.[A-Za-z_][A-Za-z0-9_]*)*)", t)
        return m.group(1) if m else t
    if kw in ("init", "subscript", "deinit"):
        m = re.match(r"(init[?!]?|subscript|deinit)(\s*<[^(]*>)?\s*(\([^)]*\))?", t)
        return (m.group(1) + (m.group(3) or "")) if m else kw
    m = re.match(r"(?:class\s+)?" + kw + r"\s+(`?[^\s(<:{=`]+`?)", t)
    if m:
        name = m.group(1)
        if kw == "func":
            m2 = re.match(r"func\s+[^\s(<]+\s*(?:<.*?>)?\s*\((.*)", t)
            if m2:
                # extract argument labels
                labels = re.findall(r"(?:^|,\s*)(?:@[A-Za-z_]+\s+)*([A-Za-z_`][A-Za-z0-9_`]*)(?:\s+[A-Za-z_`][A-Za-z0-9_`]*)?\s*:", m2.group(1).split(")")[0])
                name = name + "(" + "".join(l + ":" for l in labels) + ")"
        return name
    return t[:60]


def main():
    path = sys.argv[1]
    module = sys.argv[2] if len(sys.argv) > 2 else ""
    lines = open(path, encoding="utf-8").read().split("\n")
    # scope stack entries: dict(kind='type'|'body', name, mac)
    stack = [{"kind": "type", "name": "", "mac": None}]
    if_stack = []
    pending_attrs = []
    pending_attr_line = None
    pending_decl = None  # decl awaiting its '{'
    for idx, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if line.startswith("#if"):
            if_stack.append([list(stack), None])
            continue
        if line.startswith("#else") or line.startswith("#elseif"):
            if if_stack:
                snap = if_stack[-1]
                snap[1] = list(stack)
                stack = list(snap[0])
            pending_attrs = []
            continue
        if line.startswith("#endif"):
            if if_stack:
                snap = if_stack.pop()
                # keep state from the last branch
            continue
        top = stack[-1]
        in_body = any(s["kind"] == "body" for s in stack)
        attrs, rest = split_attrs(line)
        decl = None
        if not in_body:
            if attrs and not rest.strip():
                if not pending_attrs:
                    pending_attr_line = idx
                pending_attrs.extend(attrs)
                continue
            kw, text = strip_modifiers(rest)
            if kw in DECL_KW:
                all_attrs = pending_attrs + attrs
                mac = mac_availability(all_attrs)
                parent_mac = top.get("eff")
                eff = dict(parent_mac) if parent_mac else {"intro": None, "deprecated": None, "obsoleted": None, "unavailable": False}
                if mac["intro"]:
                    eff["intro"] = mac["intro"]
                if mac["deprecated"]:
                    eff["deprecated"] = mac["deprecated"]
                if mac["obsoleted"]:
                    eff["obsoleted"] = mac["obsoleted"]
                if mac["unavailable"]:
                    eff["unavailable"] = True
                name = decl_name(kw, text)
                toks = rest.split()
                pre = []
                for t in toks:
                    if t == kw or t.startswith(kw + "<") or t.startswith(kw + "(") or t in ("class", "func", "var", "let", "init", "struct", "enum", "protocol", "extension", "typealias", "subscript", "case", "macro", "actor", "associatedtype", "deinit"):
                        break
                    pre.append(t)
                nonpublic = any(t in ("package", "internal", "private", "fileprivate") or t.startswith(("package(", "internal(", "private(")) for t in pre) or any(a.startswith("@_spi") for a in all_attrs)
                if top.get("nonpublic"):
                    nonpublic = True
                qual = ".".join([s["name"] for s in stack if s["name"]] + [name]) if kw != "extension" else name
                decl = {
                    "module": module, "line": idx, "attr_line": pending_attr_line or idx,
                    "kw": kw, "name": name, "qual": qual,
                    "scope": ".".join(s["name"] for s in stack if s["name"]),
                    "sig": re.sub(r"\s+", " ", (" ".join(all_attrs) + " " + rest).strip())[:3000],
                    "decl": re.sub(r"\s+", " ", text)[:3000],
                    "own": mac, "eff": eff, "nonpublic": nonpublic,
                }
                print(json.dumps(decl))
                pending_attrs = []
                pending_attr_line = None
                pending_decl = decl
            elif rest.strip():
                # continuation line (where clause etc.)
                pass
        braces = brace_delta(line)
        for b in braces:
            if b == "{":
                if in_body or stack[-1]["kind"] == "body":
                    stack.append({"kind": "body", "name": "", "eff": stack[-1].get("eff")})
                elif pending_decl is not None:
                    pd = pending_decl
                    if pd["kw"] in TYPE_KW:
                        nm = pd["name"]
                        if pd["kw"] == "extension":
                            nm = re.sub(r"<.*", "", nm)
                            nm = re.sub(r"^(SwiftUI|SwiftUICore|Charts|Observation|Swift|Foundation|CoreFoundation|CoreGraphics|AppKit|Combine)\.", "", nm)
                        stack.append({"kind": "type", "name": nm, "eff": pd["eff"], "nonpublic": pd.get("nonpublic")})
                    else:
                        stack.append({"kind": "body", "name": "", "eff": pd["eff"]})
                    pending_decl = None
                else:
                    stack.append({"kind": "body", "name": "", "eff": stack[-1].get("eff")})
            else:
                if len(stack) > 1:
                    stack.pop()
                in_body = any(s["kind"] == "body" for s in stack)
        if decl is not None and "{" in braces:
            pending_decl = None
        if decl is not None and pending_decl is decl and decl["kw"] not in TYPE_KW:
            # non-type decl without brace on this line: still may get '{' later only for
            # multi-line funcs; keep pending until next decl.
            pass


if __name__ == "__main__":
    main()
