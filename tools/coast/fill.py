import sys,os,numpy as np
sys.path.insert(0,'/tmp/colldump')
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../OpenGOAL/goal_src/jak1/engine/gfx/ocean'))
from oceanmask import grid
dt=np.dtype([('x','<f4'),('y','<f4'),('z','<f4'),('flags','<u4'),('nx','<i2'),('ny','<i2'),('nz','<i2'),('pad','<u2'),('pat','<u4'),('pad2','<u4')])
T=96.0; SX=SZ=-2304.0
land=np.array(grid('village1',None))            # [zt][xt] True = land (no water drawn)
geo=np.zeros((48,48),bool)                        # some level has geometry in the tile
for lev in ['village1','beach','jungle','firecanyon','village2','swamp','sunken','rolling','misty','training']:
    v=np.fromfile(f'/tmp/colldump/{lev}.fr3.coll',dtype=dt)
    xt=np.floor((v['x']/4096-SX)/T).astype(int); zt=np.floor((v['z']/4096-SZ)/T).astype(int)
    ok=(xt>=0)&(xt<48)&(zt>=0)&(zt<48); geo[zt[ok],xt[ok]]=True
ocean=~land
empty=land&~geo
# Chebyshev distance (tiles) to the nearest ocean tile
dist=np.full((48,48),99)
for zt in range(48):
    for xt in range(48):
        if not empty[zt,xt]: continue
        for r in range(0,5):
            if ocean[max(0,zt-r):zt+r+1, max(0,xt-r):xt+r+1].any(): dist[zt,xt]=r; break
fill=np.zeros((48,48),bool)
for zt in range(48):
    for xt in range(48):
        x0=SX+xt*T; z0=SZ+zt*T
        if empty[zt,xt] and dist[zt,xt]<=3 and 200<=x0<=700 and -1500<=z0<=-300: fill[zt,xt]=True
print('fill tiles',fill.sum())
for zt in range(48):
    z0=SZ+zt*T
    if not (-1600<=z0<=-200): continue
    print(f'{z0:7.0f} '+''.join('F' if fill[zt,xt] else ('~' if ocean[zt,xt] else ('L' if geo[zt,xt] else '#')) for xt in range(16,36)), f'  (x from {SX+16*T:.0f})')
np.savez('/tmp/coast/tiles.npz',land=land,geo=geo,fill=fill)
