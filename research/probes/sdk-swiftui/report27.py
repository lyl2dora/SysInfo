import json,sys
for m in ["SwiftUI","SwiftUICore","Charts","Observation"]:
    recs=[json.loads(l) for l in open(f"v27/{m}.jsonl")]
    print(f"\n######## {m}: declarations with effective macOS intro 27.0 (own attr marked *)")
    for r in recs:
        if r["eff"]["intro"]=="27.0" and not r["eff"]["unavailable"] and not r.get("nonpublic"):
            mark="*" if r["own"]["intro"]=="27.0" else " "
            print(f"{mark} L{r['line']:>6} [{r['scope']}] {r['decl'][:220]}")
            if mark=="*": print(f"           avail: {' '.join(r['own']['raw'])[:200]}")
