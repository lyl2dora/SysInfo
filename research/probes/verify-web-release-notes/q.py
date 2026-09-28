import sys,re
f=sys.argv[1]; t=open(f).read()
for p in sys.argv[2:]:
    ms=list(re.finditer(re.escape(p),t,re.I))
    if not ms: print('[%s] NOT FOUND: %s'%(f,p)); continue
    m=ms[0]; print('[%s] %s (%d hits) => %s\n'%(f,p,len(ms),t[max(0,m.start()-220):m.end()+320]))
