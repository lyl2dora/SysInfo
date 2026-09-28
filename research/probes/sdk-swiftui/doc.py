import sys,re
def blocks(fn):
    cur=None; out={}
    for l in open(fn,errors='ignore'):
        l=l.rstrip('\n')
        m=re.match(r'^(s:[A-Za-z0-9_]+)',l)
        if m:
            cur=m.group(1); out.setdefault(cur,[]); continue
        if cur and l.startswith('///'):
            out[cur].append(l)
    return out
import glob
allb={}
for fn in glob.glob('*27.swiftdoc.strings.txt'):
    for k,v in blocks(fn).items():
        allb[(fn.split('27')[0],k)]=v
for q in sys.argv[1:]:
    hits=[(k,v) for k,v in allb.items() if q in k[1]]
    for k,v in hits[:4]:
        print(f"=== {k[0]} {k[1]}")
        print("\n".join(v[:int(__import__('os').environ.get('N','14'))]))
