import json,sys
def inl(x):
    out=[]
    for i in x or []:
        t=i.get('type')
        if t=='text': out.append(i['text'])
        elif t=='codeVoice': out.append('`'+i['code']+'`')
        elif t in('emphasis','strong','newTerm','inlineHead'): out.append(inl(i.get('inlineContent')))
        elif t=='reference': out.append(i.get('title') or i.get('identifier','').split('/')[-1])
        elif t=='link': out.append(i.get('title',''))
        elif t=='image': pass
        else: out.append(inl(i.get('inlineContent')))
    return ''.join(out)
def blk(x,d=0,o=None):
    for b in x or []:
        t=b.get('type')
        if t=='heading': o.append('\n'+'#'*b.get('level',2)+' '+b.get('text',''))
        elif t=='paragraph': o.append(inl(b.get('inlineContent')))
        elif t in('unorderedList','orderedList'):
            for it in b.get('items',[]):
                s=[];blk(it.get('content'),d+1,s);o.append('  '*d+'- '+' '.join(s))
        elif t=='codeListing': o.append('```\n'+'\n'.join(b.get('code',[]))+'\n```')
        elif t=='aside': s=[];blk(b.get('content'),d,s);o.append('> '+b.get('name',b.get('style',''))+': '+' '.join(s))
        elif t=='table':
            for r in b.get('rows',[]):
                cells=[]
                for c in r: s=[];blk(c,d,s);cells.append(' '.join(s))
                o.append(' | '.join(cells))
        else:
            if 'content' in b: blk(b['content'],d,o)
            if 'inlineContent' in b: o.append(inl(b['inlineContent']))
d=json.load(open(sys.argv[1]))
o=[d.get('metadata',{}).get('title','')]
for s in d.get('primaryContentSections',[]): blk(s.get('content'),0,o)
if 'abstract' in d: o.insert(1,inl(d['abstract']))
print('\n'.join(o))
