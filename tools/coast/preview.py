import numpy as np, struct
d=np.fromfile('/tmp/coast/tris.bin',dtype=np.dtype([('x','<f4'),('y','<f4'),('z','<f4'),('s','<f4'),('t','<f4'),('m','<i4'),('l','<i4')]))
t=np.load('/tmp/coast/tiles.npz'); land=t['land']
X0,X1,Z0,Z1=150,620,-1300,-250; S=2.0
W=int((X1-X0)/S); Hh=int((Z1-Z0)/S)
img=np.zeros((Hh,W,3),np.uint8)
# background: ocean blue / land-without-terrain black / other dark grey
for j in range(Hh):
    for i in range(W):
        x=X0+i*S; z=Z0+j*S; xt=int((x+2304)//96); zt=int((z+2304)//96)
        img[j,i]=(30,60,140) if not land[zt,xt] else (0,0,0)
tri=d.reshape(-1,3)
col={0:np.array([70,150,50]),1:np.array([120,110,100]),2:np.array([210,190,130])}
for tr in tri:
    if abs(tr['y'].max()-tr['y'].min())>10 and tr['y'].min()<=-11.9: continue  # skip skirts
    cx=tr['x'].mean(); cz=tr['z'].mean(); y=tr['y'].mean()
    i=int((cx-X0)/S); j=int((cz-Z0)/S)
    if 0<=i<W and 0<=j<Hh:
        c=col[int(tr['m'][0])]*(0.55+0.45*np.clip(y/45,0,1)) if y>0 else np.array([40,90,120])
        img[max(0,j-1):j+2,max(0,i-1):i+2]=np.clip(c,0,255)
img=img[::-1]  # north up (larger z at top)
with open('/tmp/coast/preview.ppm','wb') as f:
    f.write(b'P6 %d %d 255\n'%(W,Hh)); f.write(img.tobytes())
