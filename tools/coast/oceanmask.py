import re,sys
t=open('ocean-tables.gc').read()
def table(name):
    i=t.index(f'(define {name}')
    j=t.index('\n(define',i+5)
    return t[i:j]
def indices(name):
    b=table(name); vals=re.findall(r'#x[0-9a-f]+|\b\d+\b',b.split("36",1)[1])
    return [int(v[2:],16) if v.startswith('#x') else int(v) for v in vals][:36]
def masks(name):
    b=table(name)
    out=[]
    for m in re.finditer(r"\(new 'static 'ocean-mid-mask(?: :dword #x([0-9a-f]+))?\)",b):
        out.append(int(m.group(1),16) if m.group(1) else 0)
    return out
def grid(mapname,start):
    idx=indices(f'*ocean-mid-indices-{mapname}*'); ms=masks(f'*ocean-mid-masks-{mapname}*')
    g=[[None]*48 for _ in range(48)]  # g[zt][xt] True=land/skip
    for bz in range(6):
        for bx in range(6):
            v=idx[6*bz+bx]
            for r in range(8):
                for c in range(8):
                    if v==0xffff: land=True
                    else:
                        d=ms[v]; byte=(d>>(8*r))&0xff; land=bool(byte&(1<<c))
                    g[bz*8+r][bx*8+c]=land
    return g
