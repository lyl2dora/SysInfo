import re,sys
path=sys.argv[1]
L=open(path).read().split("\n")
i=0;out=[]
while i<len(L):
    s=L[i].strip()
    if s.startswith("@available") or s.startswith("@_"):
        attrs=[];j=i
        while j<len(L) and (L[j].strip().startswith("@available") or L[j].strip().startswith("@_originallyDefinedIn") or L[j].strip().startswith("@_documentation") or L[j].strip().startswith("@_spi") or L[j].strip().startswith("@_disfavored") or L[j].strip().startswith("@_Concurrency") or L[j].strip().startswith("@_alwaysEmit") or L[j].strip().startswith("@export") ):
            attrs.append(L[j].strip()); j+=1
            if j<len(L) and "@available" in L[j] and not L[j].strip().startswith("@"): break
        a=" ".join(attrs)
        mac27 = re.search(r"macOS 27\.0|anyAppleOS 27\.0",a) and not re.search(r"@available\(macOS, unavailable\)",a)
        if mac27 and j<len(L):
            out.append(f"{i+1}: {L[j].strip()[:230]}")
        i=max(j,i+1)
    else: i+=1
print("\n".join(out))
