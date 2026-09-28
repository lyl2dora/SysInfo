# tele_w3.py - PowerTelemetryData accumulators vs integral of SMC PDTR, window 3 (rail2.csv); plus wall/DC ratio
import numpy as np, csv, time
rows = list(csv.reader(open('rail2.csv'))); h = rows[0]; rows = [r for r in rows[1:] if len(r) == len(h)]
c = lambda k: np.array([float(r[h.index(k)]) for r in rows])
t = c('epoch'); pd = c('PDTR'); acc = c('T_AccumulatedSystemPowerIn'); cnt = c('T_SystemPowerInAccumulatorCount'); wall = c('T_AccumulatedWallEnergyEstimate'); se = c('T_AccumulatedSystemEnergyConsumed')
upd = np.where(np.diff(cnt) != 0)[0] + 1
B1, B2 = 1790593709.005, 1790595509.005
i1 = min(upd, key=lambda i: abs(t[i] - B1)); i2 = min(upd, key=lambda i: abs(t[i] - B2))
print('telemetry update cadence (s):', np.unique(np.round(np.diff(t[upd])))[:10])
dC = cnt[i2] - cnt[i1]; dA = (acc[i2] - acc[i1]) / 1000; dW = (wall[i2] - wall[i1]) * 3.6 / 1000; dS = (se[i2] - se[i1]) * 3.6 / 1000
for lag in (0, 60):
    m = (t > t[i1] - lag) & (t <= t[i2] - lag); dt = np.diff(np.concatenate([[t[m][0] - 1], t[m]]))
    print(f'span {time.strftime("%H:%M:%S", time.localtime(t[i1]))}->{time.strftime("%H:%M:%S", time.localtime(t[i2]))} (dCount {dC:.0f}) shifted -{lag}s: integral PDTR = {np.sum(pd[m]*dt):.1f} J')
print(f'AccumulatedSystemPowerIn delta/1000 = {dA:.1f} J (mean {dA/dC:.3f} W); AccumulatedSystemEnergyConsumed*3.6 = {dS:.1f} J; AccumulatedWallEnergyEstimate*3.6 = {dW:.1f} J (mean {dW/dC:.3f} W) -> DC/wall = {dA/dW:.3f}')
