import re,sys,difflib
def norm(p):
    s=open(p,errors='replace').read()
    s=re.sub(r'/\*.*?\*/','',s,flags=re.S)
    s=re.sub(r'//[^\n]*','',s)
    toks=re.findall(r'[A-Za-z_][A-Za-z0-9_]*|\d+(?:\.\d+)*|\S',s)
    # join into statements by ;
    out=[];cur=[]
    for t in toks:
        cur.append(t)
        if t in(';','{','}'): out.append(' '.join(cur));cur=[]
    if cur: out.append(' '.join(cur))
    return out
a=norm(sys.argv[1]);b=norm(sys.argv[2])
for l in difflib.unified_diff(a,b,lineterm='',n=0):
    if l.startswith(('---','+++','@@')): continue
    print(l)
