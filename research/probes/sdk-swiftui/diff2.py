import json,re,sys
from collections import defaultdict
sys.argv=['x']
exec(open('diff_sdk.py').read().split("def main")[0])
def namekey(r):
    return (norm(r['scope']), r['kw'], norm(r['name']))
out=open('diff_paired.txt','w')
for g,mods in {"SwiftUI+SwiftUICore":["SwiftUI","SwiftUICore"],"Charts":["Charts"],"Observation":["Observation"]}.items():
    a=[r for m in mods for r in load(26,m)]; b=[r for m in mods for r in load(27,m)]
    ka=set(r['key'] for r in a); kb=set(r['key'] for r in b)
    added=[r for r in b if r['key'] not in ka and not r['eff'].get('unavailable')]
    removed=[r for r in a if r['key'] not in kb and not r['eff'].get('unavailable')]
    # dedupe
    def dd(l):
        s=set();o=[]
        for r in l:
            if r['key'] in s: continue
            s.add(r['key']);o.append(r)
        return o
    added=dd(added); removed=dd(removed)
    rn=defaultdict(list)
    for r in removed: rn[namekey(r)].append(r)
    an=defaultdict(list)
    for r in added: an[namekey(r)].append(r)
    pure_add=[r for r in added if namekey(r) not in rn]
    pure_rem=[r for r in removed if namekey(r) not in an]
    changed=[k for k in an if k in rn]
    out.write(f"\n######## {g}: PURE ADDITIONS (no same-name decl removed) [{len(pure_add)}]\n")
    for r in pure_add:
        out.write(f"{r['module']}:L{r['line']} [{r['scope']}] {r['kw']} {r['decl'][:200]} || {fmt_av(r)}\n")
    out.write(f"\n######## {g}: PURE REMOVALS (macOS-available in 26.5, gone in 27) [{len(pure_rem)}]\n")
    for r in pure_rem:
        out.write(f"{r['module']}:L{r['line']}(26.5) [{r['scope']}] {r['kw']} {r['decl'][:200]} || {fmt_av(r)}\n")
    out.write(f"\n######## {g}: SIGNATURE CHANGED (same name, different normalized decl) [{len(changed)}]\n")
    for k in changed:
        for r in rn[k]: out.write(f"  - 26.5 L{r['line']} [{r['scope']}] {norm(r['decl'])}\n")
        for r in an[k]: out.write(f"  + 27   L{r['line']} [{r['scope']}] {norm(r['decl'])} || {fmt_av(r)}\n")
    print(g, "pure_add", len(pure_add), "pure_rem", len(pure_rem), "changed", len(changed))
