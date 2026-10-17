# 调研探针（2026-09-28）

这些是 `docs/research/2026-09-28-capability-sdk-audit.md` 背后的只读探针，在 Mac mini M5 Pro / macOS 27.0 (26A428) 上编译运行过。它们相当于每条数据路径的参考实现：SMC、IOReport、coalition、NVMe SMART、IFMIB、CoreHID UPS、菜单栏运行时等。

- 每个目录对应一个域：`<域>/` 是初测，`<域>-review/` 是 skeptic 复测，`gap-*/` 是补漏，`sdk-*`/`verify-*`/`web-*` 是 SDK 与文档调研。
- 版本库里只有源码（`.swift/.c/.m/.h/.py/.sh`、探针 app 的 `Info.plist`、`.entitlements`），另有 `sdk-swiftui/` 下两份 `.md` 发布说明副本。其他网页和文档快照（`web-release-notes/`、`verify-web-release-notes/` 等目录下的 `.txt/.json`）只保存在本地。二进制文件、原始日志和大体积 dump 都没有保留。
- **文本输出（`.txt/.csv/.json`）和数据 dump（ioreg/diskutil 导出的 `.plist`）里含本机标识**，如磁盘序列号、卷 UUID、MAC、IP、设备名。这些文件已在 `.gitignore` 中排除，只保存在本地。
- 编译示例：`xcrun swiftc -O x.swift -o x`；IOReport 相关的加 `-lIOReport`；C 探针用 `xcrun clang -framework IOKit -framework CoreFoundation`。

## power-thermal/（2026-10-15，功耗与散热模块边界补测）
- 在 M5 Pro 与 M4 Pro（macOS 27.0.1）上同时跑：`build.sh <outdir>` 编译，`orchestrate.sh <dir> <tag>` 等到 PMGR 批次边界后在 30 分钟窗口里跑负载（`ROUND=2` 为第二轮），`analyze.py` / `analyze_r2.py` / `tele.py` 分析，`costbench.c` 测真实节奏开销。
- 结论见 `docs/design/power-thermal-boundary.md`。原始记录与输出（`out/`）按 `.gitignore` 只留在本地。

## memory-module/（2026-10-16，内存模块边界复核）
- `mem_probe.c`：活动监视器口径的页面队列（sysctl 与 host_statistics64 对照）、压力、Swap、ECC / MTE、同 uid footprint 全扫耗时、IOReport「DCS BW」通道发现（M5 组名 `PMP0`、M4 为 `PMP`）。在 M5 Pro 与 M4 Pro 上各跑一次，输出 `mem_probe_m5.txt` / `mem_probe_m4.txt` 按 `.gitignore` 只留在本地。
- 编译：`xcrun clang -O2 -o mem_probe mem_probe.c -framework CoreFoundation`。结论见 `docs/design/memory.md` §1。

## storage-module/（2026-10-16，存储模块边界）
- `storage_probe.c`：物理盘清单（判定规则、RAID 关系、驱动 Statistics、SMART 全字段与 Identify），SMART 读取开销（重建 plugin 与常驻 plugin），以及读 SMART 时 IOReport「NVMe Power States」的驻留。只读，不打印序列号与 UUID。结论见 `docs/design/storage.md` §1。

## gpu-module/（2026-10-16，GPU 与加速器模块边界）
- `gpu_struct.c`：只读结构比对（IOReport GPU / 媒体 / ANE 通道、pmgr DVFS 表、AGX 与 ANE 的 IORegistry、SMC `Tg*`/`Ta*`、coalition 槽位 8/41/38/39）。
- `gpu_watch.c`：1 Hz 记录器（GPUPH 等状态通道、GPU Energy、PMGR 批次、媒体中断、PMP 带宽、Tg/Ta、coalition、ANE 电源状态），附每段读取的线程 CPU。
- `orchestrate.sh` 在一个 PMGR 30 分钟窗口里跑负载序列（每段 ≤60 s），`tiny.sh` 补测小 kernel，`costbench_gpu.c` 测真实节奏开销，`analyze.py` 汇总。`build.sh <outdir>` 编译全部（负载程序沿用 power-thermal/、gpu/、gpu-review/ 的源码）。
- 结论见 `docs/design/gpu.md`。原始输出（`out/`）按 `.gitignore` 只留在本地。

## app-activity/（2026-10-17，应用活动模块开工前）
- `assert_watch.c`：电源断言的可见范围、归属（uid、coalition、代他人持有）、开销、变化通知（含私有 `IOPMAssertionNotify` 登记）、私有活动日志、内核侧断言。会自建一个约 3 s 的断言后释放，并派生一次 `caffeinate -d -t 1`。
- `appact_density.c`：每分钟活跃应用密度、各列 Top-K 并集的覆盖率与行数，以及应用能耗合计（槽位 11+41+39）对 SMC `PZC0` / `PDTR` 的覆盖。
- `appact_cost.c`：应用活动窗口全表刷新（约 660 个 coalition）在 1 / 2 / 5 s 真实节奏下的开销。
- 编译：`xcrun clang -O2 -framework IOKit -framework CoreFoundation <x>.c -o <x>`（`appact_*` 引用 `../cpu-module/processes/coal.h`）。结论见 `docs/design/app-activity.md` §1。输出（`out/`）按 `.gitignore` 只留在本地。
