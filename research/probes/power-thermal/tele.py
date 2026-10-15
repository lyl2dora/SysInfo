# tele.py - PowerTelemetryData 累加器与 PDTR 按 60 s 更新逐段对账。usage: tele.py <dir> <tag>
import csv,sys,numpy as np
D,T=sys.argv[1],sys.argv[2]
rows=list(csv.reader(open(f'{D}/pt_{T}.csv')));h=rows[0];rows=[r for r in rows[1:] if len(r)==len(h)]
c=lambda k: np.array([float(r[h.index(k)]) for r in rows])
t=c('epoch');pd=c('PDTR');acc=c('T_AccumulatedSystemPowerIn');cnt=c('T_SystemPowerInAccumulatorCount');w=c('T_AccumulatedWallEnergyEstimate');se=c('T_AccumulatedSystemEnergyConsumed');ld=c('T_AccumulatedSystemLoad')
spi=c('T_SystemPowerIn'); wee=c('T_WallEnergyEstimate')
up=np.where(np.diff(cnt)!=0)[0]+1
print('updates',len(up),'cadence',np.unique(np.round(np.diff(t[up])))[:6])
for lag in (0,30,60):
  rs=[]
  for a,b in zip(up[:-1],up[1:]):
    m=(t>t[a]-lag)&(t<=t[b]-lag); p=np.mean(pd[m]); dA=(acc[b]-acc[a])/1000; dC=cnt[b]-cnt[a]
    rs.append((p,dA/dC,(w[b]-w[a])*3.6/1000/dC,(se[b]-se[a])*3.6/1000/dC,dC))
  rs=np.array(rs); r=rs[:,1]/rs[:,0]
  print(f'lag {lag}: AccIn/PDTR median {np.median(r):.3f} min {r.min():.3f} max {r.max():.3f}; corr {np.corrcoef(rs[:,0],rs[:,1])[0,1]:.3f}')
print(' PDTR   AccIn/cnt  Wall*3.6/cnt  SysEnergy*3.6/cnt dC (lag 0)')
for x in rs[::3]: print(' '.join(f'{v:8.2f}' for v in x))
print('SystemPowerIn snapshot sample',spi[:5],'WallEnergyEstimate',wee[:5])
