import json,sys
d=json.load(open(sys.argv[1]))
out=[]
def inl(x):
    s=''
    for i in x or []:
        t=i.get('type')
        if t=='text': s+=i['text']
        elif t=='codeVoice': s+='`'+i['code']+'`'
        elif 'inlineContent' in i: s+=inl(i['inlineContent'])
        elif t=='reference': s+='['+i.get('identifier','').split('/')[-1]+']'
    return s
def walk(c,depth=0):
    for b in c:
        t=b.get('type')
        if t=='heading': out.append('\n'+'#'*b.get('level',2)+' '+b.get('text',''))
        elif t=='paragraph': out.append(inl(b.get('inlineContent')))
        elif t in('unorderedList','orderedList'):
            for it in b['items']:
                out.append('  '*depth+'- '); walk(it.get('content',[]),depth+1)
        elif t=='codeListing': out.append('```\n'+'\n'.join(b.get('code',[]))+'\n```')
        elif t=='aside': out.append('> '+b.get('name','')); walk(b.get('content',[]),depth)
        elif 'content' in b: walk(b['content'],depth)
for s in d.get('primaryContentSections',[]):
    walk(s.get('content',[]))
print('\n'.join(out))
