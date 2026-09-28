import re,difflib
lines=open('diff_paired.txt').read().split('\n')
out=[]
sec=None
i=0
pairs=[]
cur_minus=[];cur_plus=[]
for l in lines:
    if l.startswith('########'):
        sec=l; out.append(l); continue
    if 'SIGNATURE CHANGED' not in (sec or ''): continue
    if l.startswith('  - 26.5'):
        if cur_plus:
            pairs.append((cur_minus,cur_plus)); cur_minus=[];cur_plus=[]
        cur_minus.append(l)
    elif l.startswith('  + 27'):
        cur_plus.append(l)
if cur_minus: pairs.append((cur_minus,cur_plus))
def body(l):
    return re.sub(r'^\s*[-+] (26\.5|27)\s+L\d+ ','',l).split(' || ')[0]
def tok(s): return re.findall(r'\w+|[^\w\s]',s)
res=[]
for mi,pl in pairs:
    for a,b in zip(mi,pl):
        ta,tb=tok(body(a)),tok(body(b))
        sm=difflib.SequenceMatcher(None,ta,tb)
        ch=[]
        for op,i1,i2,j1,j2 in sm.get_opcodes():
            if op!='equal':
                ch.append(f"{op}: '{' '.join(ta[i1:i2])}' -> '{' '.join(tb[j1:j2])}'")
        loc=re.search(r'L\d+ \[[^\]]*\]',b).group(0)
        name=body(b)[:70]
        res.append(f"{loc} {name} :: "+' ; '.join(ch)[:300])
    if len(mi)!=len(pl):
        res.append(f"   (count mismatch: {len(mi)} old vs {len(pl)} new) {body(mi[0])[:80]}")
open('diff_sigchanges.txt','w').write('\n'.join(res)+'\n')
print(len(res))
