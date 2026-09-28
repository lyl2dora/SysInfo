import json,sys
def inl(items, refs):
    out=[]
    for it in items or []:
        t=it.get('type')
        if t=='text': out.append(it['text'])
        elif t=='codeVoice': out.append('`'+it['code']+'`')
        elif t in ('emphasis','strong','newTerm'): out.append(inl(it.get('inlineContent'),refs))
        elif t=='reference':
            r=refs.get(it.get('identifier'),{})
            out.append(r.get('title') or it.get('identifier',''))
        elif t=='link': out.append(it.get('title') or it.get('destination',''))
        elif t=='image': pass
        else: out.append(inl(it.get('inlineContent'),refs))
    return ''.join(out)
def blk(items, refs, depth=0, out=None):
    for b in items or []:
        t=b.get('type')
        if t=='heading': out.append('\n'+'#'*b.get('level',2)+' '+b.get('text',''))
        elif t=='paragraph': out.append('  '*depth+inl(b.get('inlineContent'),refs))
        elif t in ('unorderedList','orderedList'):
            for li in b.get('items',[]):
                sub=[]; blk(li.get('content'),refs,depth+1,sub)
                if sub: sub[0]='  '*depth+'- '+sub[0].lstrip()
                out.extend(sub)
        elif t=='aside':
            sub=[]; blk(b.get('content'),refs,depth,sub)
            out.append('  '*depth+'['+b.get('name',b.get('style',''))+'] '+' '.join(s.strip() for s in sub))
        elif t=='codeListing': out.append('```\n'+'\n'.join(b.get('code',[]))+'\n```')
        elif t=='table':
            for row in b.get('rows',[]):
                cells=[]
                for c in row:
                    sub=[]; blk(c,refs,0,sub); cells.append(' '.join(sub))
                out.append(' | '.join(cells))
        else:
            if 'content' in b: blk(b['content'],refs,depth,out)
            elif 'inlineContent' in b: out.append(inl(b['inlineContent'],refs))
    return out
d=json.load(open(sys.argv[1]))
refs=d.get('references',{})
out=[]
out.append('TITLE: '+d.get('metadata',{}).get('title',''))
out.append(inl(d.get('abstract'),refs))
for sec in d.get('primaryContentSections',[]):
    blk(sec.get('content'),refs,0,out)
for ts in d.get('topicSections',[]) or []:
    out.append('\n## TOPIC: '+ts.get('title',''))
    for i in ts.get('identifiers',[]):
        r=refs.get(i,{}); out.append('- '+r.get('title','')+'  '+r.get('url',''))
print('\n'.join(out))
