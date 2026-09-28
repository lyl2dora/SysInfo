import json,sys
d=json.load(open(sys.argv[1]))
out=[]
def inl(xs):
    s=""
    for x in xs or []:
        t=x.get("type")
        if t=="text": s+=x["text"]
        elif t=="codeVoice": s+="`"+x["code"]+"`"
        elif t in("emphasis","strong","newTerm"): s+=inl(x.get("inlineContent"))
        elif t=="reference": s+=x.get("identifier","").split("/")[-1]
        elif t=="link": s+=x.get("title","")
        else: s+=inl(x.get("inlineContent"))
    return s
def blk(xs,ind=""):
    for b in xs or []:
        t=b.get("type")
        if t=="heading": out.append("\n"+"#"*b.get("level",2)+" "+b.get("text",""))
        elif t=="paragraph": out.append(ind+inl(b.get("inlineContent")))
        elif t in("unorderedList","orderedList"):
            for it in b.get("items",[]): out.append(ind+"- "); blk(it.get("content"),ind+"  ")
        elif t=="codeListing": out.append(ind+"```\n"+"\n".join(b.get("code",[]))+"\n```")
        elif t=="aside": blk(b.get("content"),ind+"> ")
        else: blk(b.get("content"),ind)
for s in d.get("primaryContentSections",[]): blk(s.get("content"))
print("\n".join(out))
