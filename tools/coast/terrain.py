# Stand-in coastline terrain (see README.md): steep jungle-style sea cliffs.
# Output: /tmp/coast/tris.bin (x y z s t floats in m/uv, material int, light int per vertex) and
# /tmp/coast/coast-heights.gc (GOAL collision grid). Materials: 0 grass, 1 rock, 2 sand, 3 grass fringe.
import numpy as np, struct, math
d=np.load('/tmp/coast/tiles.npz'); land=d['land']; fill=d['fill']
T=96.0; SX=SZ=-2304.0; C=3.0
X0,X1,Z0,Z1=192.0,576.0,-1248.0,-288.0
nx=int((X1-X0)/C); nz=int((Z1-Z0)/C)
def tile_of(x,z):
    xt=np.floor((x-SX)/T).astype(int); zt=np.floor((z-SZ)/T).astype(int)
    return np.clip(zt,0,47),np.clip(xt,0,47)
cx=X0+C*(np.arange(nx)+0.5); cz=Z0+C*(np.arange(nz)+0.5)
CX,CZ=np.meshgrid(cx,cz)
zt,xt=tile_of(CX,CZ)
isocean=~land[zt,xt]; isfill=fill[zt,xt]
def mind(A,B):
    out=np.empty(len(A))
    for k in range(0,len(A),1024):
        a=A[k:k+1024]; out[k:k+1024]=np.sqrt(((a[:,None,:]-B[None,:,:])**2).sum(-1)).min(1)
    return out
# distances on a coarse 6 m grid (fast), then upsampled
c6x=X0+6.0*(np.arange(nx//2)+0.5); c6z=Z0+6.0*(np.arange(nz//2)+0.5)
P6=np.stack(np.meshgrid(c6x,c6z),-1).reshape(-1,2)
z6,x6=tile_of(P6[:,0],P6[:,1]); oc6=~land[z6,x6]; fl6=fill[z6,x6]
dist6=np.where(oc6,-mind(P6,P6[~oc6]),mind(P6,P6[oc6])).reshape(nz//2,nx//2)
dfill6=mind(P6,P6[fl6]).reshape(nz//2,nx//2)
def up(a): return np.repeat(np.repeat(a,2,0),2,1)[:nz,:nx]
def fbm(x,z,oct=4,f=0.012,seed=0.0):
    s=0; a=1; tot=0
    for o in range(oct):
        s+=a*(np.sin(x*f+seed*1.3+o*2.1)*np.cos(z*f*1.13+seed*0.7+o*1.7)+np.sin((x+z)*f*0.71+o*3.3+seed))*0.5
        tot+=a; a*=0.5; f*=2.03
    return s/tot
ss=lambda a,b,x: (lambda t: t*t*(3-2*t))(np.clip((x-a)/(b-a),0,1))
gx=X0+C*np.arange(nx+1); gz=Z0+C*np.arange(nz+1); GX,GZ=np.meshgrid(gx,gz)
# corner distance from the 6 m field (bilinear-ish via neighbour average of upsampled cells)
D=up(dist6); pad=np.pad(D,1,mode='edge'); dc=(pad[:-1,:-1]+pad[1:,:-1]+pad[:-1,1:]+pad[1:,1:])/4
# jagged shoreline: push the cliff in and out along the coast, plus small coves
dj=dc+9.0*fbm(GX,GZ,3,0.035,1.0)+4.0*fbm(GX,GZ,2,0.11,5.0)
cliffH=58.0+16.0*fbm(GX,GZ,3,0.008,2.0)            # 42..74 m cliff tops
toe=4.0+3.0*(fbm(GX,GZ,2,0.05,3.0)+1)               # 4..10 m of shelf/beach before the cliff
width=7.0+4.0*(fbm(GX,GZ,2,0.04,4.0)+1)             # cliff face 7..15 m wide (near vertical)
face=ss(toe,toe+width,dj)
# rock strata: ledges on the face
strata=np.floor(face*cliffH/7.0)*7.0/np.maximum(cliffH,1)
face=0.7*face+0.3*strata
# inland: a second, higher cliff tier, then ridged rocky peaks (jungle-style hills, nothing flat)
tier_at=45.0+18.0*(fbm(GX,GZ,2,0.02,7.0)+1)
tier=(25.0+12.0*fbm(GX,GZ,2,0.015,8.0))*ss(tier_at,tier_at+12.0,dj)
ridge=1.0-np.abs(fbm(GX,GZ,4,0.016,9.0))                 # ridged noise: sharp crests
peaks=30.0*ss(toe+width+15,toe+width+110,dj)*ridge**2
bumps=6.0*fbm(GX,GZ,3,0.06,10.0)*ss(toe+width,toe+width+20,dj)
H=np.where(dj>=0, -2.0+3.5*ss(0,toe,dj)+cliffH*face+tier+peaks+bumps, -2.0+dj*0.8)
H=np.maximum(H,-16.0)
emit=isfill | (isocean & (up(dist6)>-24) & (up(dfill6)<30))
sun=np.array([0.45,0.80,0.40]); sun/=np.linalg.norm(sun)
tris=[]
def emit_tri(p,uv,mat,light):
    for (x,y,z),(s,t) in zip(p,uv): tris.append((x,y,z,s,t,mat,light))
def quad_uvs(pts,mode,n,scale_u,scale_v):
    uv=[]
    for x,y,z in pts:
        if mode=='top': uv.append((x/scale_u,z/scale_v))
        elif abs(n[0])>abs(n[2]): uv.append((z/scale_u,-y/scale_v))
        else: uv.append((x/scale_u,-y/scale_v))
    su=math.floor(min(u for u,v in uv)); sv=math.floor(min(v for u,v in uv))
    return [(u-su,v-sv) for u,v in uv]
for j in range(nz):
    for i in range(nx):
        if not emit[j,i]: continue
        a=(gx[i],H[j,i],gz[j]); b=(gx[i+1],H[j,i+1],gz[j]); c=(gx[i+1],H[j+1,i+1],gz[j+1]); e=(gx[i],H[j+1,i],gz[j+1])
        n=np.cross(np.subtract(e,a),np.subtract(b,a)); n=n/np.linalg.norm(n)
        if n[1]<0: n=-n
        top=max(a[1],b[1],c[1],e[1])
        steep=n[1]<0.75
        light=int(np.clip((np.dot(n,sun)-0.25)/0.75*4,0,3))
        lip=steep and top>H[j,i]+0 and top>cliffH[j,i]-3.5 and top>20
        if lip: mat,mode,su,sv=3,'side',8.0,4.0
        elif steep: mat,mode,su,sv=1,'side',16.0,8.0
        elif top<2.5: mat,mode,su,sv=2,'top',8.0,8.0
        else: mat,mode,su,sv=0,'top',6.0,6.0
        uv=quad_uvs([a,b,c,e],mode,n,su,sv)
        emit_tri([a,b,c],[uv[0],uv[1],uv[2]],mat,light); emit_tri([a,c,e],[uv[0],uv[2],uv[3]],mat,light)
        for (di,dj_,p0,p1) in [(0,-1,a,b),(1,0,b,c),(0,1,c,e),(-1,0,e,a)]:
            ii,jj=i+di,j+dj_
            if 0<=ii<nx and 0<=jj<nz and emit[jj,ii]: continue
            if max(p0[1],p1[1])< -1.0: continue
            q0=(p0[0],-16.0,p0[2]); q1=(p1[0],-16.0,p1[2])
            sn=np.cross(np.subtract(q1,p0),np.subtract(p1,p0)); sn=sn/(np.linalg.norm(sn)+1e-9)
            uvs=quad_uvs([p0,q1,p1,q0],'side',sn,16.0,8.0)
            emit_tri([p0,q1,p1],[uvs[0],uvs[1],uvs[2]],1,1); emit_tri([p0,q0,q1],[uvs[0],uvs[3],uvs[1]],1,1)
with open('/tmp/coast/tris.bin','wb') as f:
    for x,y,z,s,t,m,l in tris: f.write(struct.pack('<5f2i',x,y,z,s,t,m,l))
mats=np.array([m for *_,m,l in tris[::3]])
print('triangles',len(tris)//3,'height range %.1f..%.1f'%(H[:-1,:-1][emit].min(),H[:-1,:-1][emit].max()),
      'materials grass/rock/sand/fringe',[int((mats==k).sum()) for k in range(4)])
# collision grid, 6 m cells: max height (m) where above -1.5 m, else -128
CN=2; gnx=nx//CN; gnz=nz//CN
grid=np.full((gnz,gnx),-128,int)
for j in range(gnz):
    for i in range(gnx):
        if not emit[j*CN:(j+1)*CN,i*CN:(i+1)*CN].any(): continue
        hh=H[j*CN:(j+1)*CN+1,i*CN:(i+1)*CN+1].max()
        if hh>-1.5: grid[j,i]=int(np.clip(math.ceil(hh),-100,127))
vals=grid.reshape(-1)
lines=['       '+' '.join(str(v) for v in vals[k:k+40]) for k in range(0,len(vals),40)]
goal=f''';; og:ios generated by tools/coast/terrain.py: heights (m, -128 = none) of the stand-in coastline between the
;; Forbidden Jungle and Rock Village, on a {gnx} x {gnz} grid of 6 m cells from x {X0:.0f} m, z {Z0:.0f} m.
(defconstant IOS_COAST_X0 (meters {X0:.0f}))
(defconstant IOS_COAST_Z0 (meters {Z0:.0f}))
(defconstant IOS_COAST_CELL (meters 6))
(defconstant IOS_COAST_NX {gnx})
(defconstant IOS_COAST_NZ {gnz})
(define *ios-coast-heights*
  (new 'static
       'array
       int8
       {len(vals)}
{chr(10).join(lines)}))
'''
open('/tmp/coast/coast-heights.gc','w').write(goal)
print('grid',gnx,gnz,'cells with terrain',(vals>-128).sum())
