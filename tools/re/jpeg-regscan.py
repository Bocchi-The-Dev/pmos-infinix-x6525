import re,sys
dis=open('/tmp/claude-0/jhw.dis').read().split('\n')
funcs={};cur=None
for l in dis:
    m=re.match(r'^([0-9a-f]+) <(.+)>:',l)
    if m: cur=m.group(2);funcs[cur]=[];continue
    if cur and l.strip(): funcs[cur].append(l)
M=0xffffffff
def imm(s):
    s=s.strip().lstrip('#'); 
    return int(s,0)
def run(name):
    rg={}
    out=[]
    for l in funcs[name]:
        m=re.match(r'\s*([0-9a-f]+):\s+(\S+)\s*(.*?)(\s+@.*)?$',l)
        if not m: continue
        a,op,args,_=m.groups()
        op=op.replace('.w','').replace('.n','')
        ar=[x.strip() for x in re.split(r',\s*(?![^\[]*\])',args)] if args else []
        def val(x):
            x=x.strip()
            if x.startswith('#'): return imm(x)
            return rg.get(x)
        def setr(d,v): 
            if v is None: rg.pop(d,None)
            else: rg[d]=v&M
        try:
            if op=='movw': setr(ar[0],imm(ar[1]))
            elif op=='movt':
                v=rg.get(ar[0]); setr(ar[0],None if v is None else (v&0xffff)|(imm(ar[1])<<16))
            elif op in('mov','movs'): setr(ar[0],val(ar[1]))
            elif op in('add','adds','sub','subs','orr','orrs','and','ands','bic'):
                if len(ar)==2: ar=[ar[0]]+ar
                x=val(ar[1]);y=val(ar[2]) if len(ar)==3 else None
                if len(ar)==4 and y is not None and ar[3].startswith('lsl'): y=(y<<imm(ar[3].split()[1]))&M
                if x is None or y is None: setr(ar[0],None)
                else:
                    f={'add':x+y,'adds':x+y,'sub':x-y,'subs':x-y,'orr':x|y,'orrs':x|y,'and':x&y,'ands':x&y,'bic':x&~y}[op]; setr(ar[0],f)
            elif op=='blx' or op=='bl':
                tgt=ar[0]
                r0,r1,r2=rg.get('r0'),rg.get('r1'),rg.get('r2')
                if tgt in('0x19f30','0x19f40'):
                    kind='W' if tgt=='0x19f30' else 'R'
                    o=None if r1 is None else (r1-0x62300000)&M
                    out.append((a,kind,o,r2 if kind=='W' else None))
                for r in('r0','r1','r2','r3','r12'): rg.pop(r,None)
            elif op.startswith('b') or op in('cbz','cbnz','push','pop','str','strd','strh','strb','stm','cmp','nop','it','bx'): 
                if op in('cbz','cbnz') or op.startswith('b'): pass
            elif op=='ldr' or op.startswith('ldr') or op=='asrs' or op=='lsrs' or op=='lsls' or op=='ubfx' or op=='bfc' or op=='bfi' or op=='uxth' or op=='mul' or op=='mvn':
                setr(ar[0],None)
            else:
                if ar and re.match(r'r\d+$',ar[0]): setr(ar[0],None)
        except Exception as e:
            if ar and re.match(r'r\d+$',ar[0]): setr(ar[0],None)
    return out
for n in sys.argv[1:]:
    print('==',n)
    for a,k,o,v in run(n):
        print(a,k,'reg 0x%x'%o if o is not None else 'reg ?', ('= 0x%x'%v) if v is not None else '')
