# 以 u32 小端数组打印 pmgr 节点里与簇/性能域相关的属性（只读，读 ioreg -a 的 plist 输出）。
import plistlib, subprocess, sys
raw = subprocess.run(["ioreg","-p","IODeviceTree","-n","pmgr","-r","-d","1","-a"],capture_output=True).stdout
d = plistlib.loads(raw)[0]
for k in ["acc-clusters","acc-cores","clusters","cluster-agent","perf-domains","mcx-fast-pcpu-frequency","acc-cluster-power-gating","cpu-apsc","die-stride","clpc","boost-agent"]:
    v = d.get(k)
    if v is None: print(k, "ABSENT"); continue
    if isinstance(v, bytes):
        u = [int.from_bytes(v[i:i+4],"little") for i in range(0,len(v)-len(v)%4,4)]
        print(f"{k} ({len(v)} B):", u[:200])
    else: print(k, repr(v)[:2000])
