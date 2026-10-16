# 内存模块：能力边界与实现规格

> 日期：2026-10-16。决策见 `docs/decisions.md` D49–D51（M1–M6、合并模式改期、K41 均由用户按推荐确认）。
> 内存模块的取舍不多，所以没有单独写讨论稿：本文 §1–§2 是边界（实测与结论），§3 起是实现规格，§11 是偏离记录。
> 证据：`research/probes/memory-module/`（2026-10-16，M5 Pro 与 M4 Pro 只读比对）、`research/probes/memory/`、`research/probes/memory-review/`（2026-09-28，只在 M5 上测过）。

## 1. 两台机器的能力矩阵

| 项 | M5 Pro（Mac17,16） | M4 Pro（Mac16,11） | 结论 |
|---|---|---|---|
| `vm.page_*` 页面队列 sysctl | 有 | 有 | 公开，不受 `host_statistics` 节流，作主路径 |
| `host_statistics64` rev6（count 104） | 是 | 是 | 被压缩、压缩比、累计计数从这里读 |
| 页面队列之和 ÷ `hw.memsize_usable`（free + internal + external + wired + 被压缩） | 0.999 | 1.000 | 用作提示项自检（±3%） |
| `kern.memorystatus_vm_pressure_level` / `_level` | 1 / 94% | 1 / 96% | 与 `memory_pressure -Q` 的「free percentage」逐位一致 |
| `vm.swapusage` | 0 | 0 | 两台都没有 swap 文件 |
| 压缩器 | 有页（压缩比 2.3） | 0 页 | M4 空闲时没有被压缩的页，压缩比显示「没有被压缩的页」 |
| `vm.mte.*` | 约 70 个键 | 没有 | MTE 只在 M5 上，诊断页按有无显示 |
| `vm.vm_ecc_corrected_count` | 9598（9 月 28 日为 1001，在涨） | 0 | 只进诊断页，含义未经验证 |
| IOReport「DCS BW」子组 | 组 `PMP0`，70 个通道 | 组 `PMP`，94 个通道 | 组名不同；按候选组 + 子组 + 通道名发现 |
| `proc_pid_rusage` 同 uid 全扫 | 674/1019 可读，4.4 ms | 529/845，5.5 ms | 回退路径可用 |
| coalition slot 40（footprint） | 与 top MEM 10/10 一致 | 10/10 一致 | Top N 主路径 |

### 1.1 口径（D49 M1）

照活动监视器：

- App = internal − purgeable；
- 已用 = App + 联动 + 被压缩；
- 已缓存文件 = external + purgeable；
- 空闲 = `vm.page_free_count`；
- 占用率 = 已用 ÷ `hw.memsize`。

`verify memory` 与 `vm_stat` 对照，联动、被压缩、App、已缓存在两台上都在 2% 以内，压力百分比与 `memory_pressure` 逐位相同。

**事实更正**：`vm.page_pageable_external_count` 含 speculative 页。M4 空闲时 speculative 约 3.4 GiB，按「空闲 = free + speculative」算，各项之和会比 `hw.memsize_usable` 多出约 3.4 GiB（`mem_probe_m4.txt` 的 queue sum 66.6 GiB 就是这么来的）。所以空闲只取 free。另外，`host_statistics64` 的 `free_count` 已经含 speculative，与 sysctl 的 `vm.page_free_count` 口径不同。

M5 上 sysctl 的空闲比 `vm_stat` 的「Pages free」稳定地少约 65 MiB（3%），M4 上只差约 30 MiB。原因未查清（疑与 M5 的 MTE 空闲标签页有关），空闲只用于构成条，对已用和占用率没有影响。

### 1.2 开销（线程 CPU，CLI 实测）

| 项 | M5 | M4 |
|---|---|---|
| `memory.vm` 一次（11 次 sysctl + host_statistics64） | 0.25–0.3 ms | 约 0.3 ms |
| `memory.bandwidth` 一次（IOReport 订阅采样） | 约 6.7 ms | 约 10 ms |
| 首次枚举 `PMP0` / `PMP` 组 | 35–50 ms | 30–60 ms |
| 内存 Top N 组装（coalition 扫描另计） | 约 9 ms（含扫描） | 约 3.8 ms（含扫描） |

所以菜单栏 1 s 的内存 widget 约 0.03% 单核，可以忽略；DRAM 带宽较贵，只在诊断页展开时采（D49 M3）。

## 2. 边界（D49）

- **纳入**：
  - 总量与构成；
  - 压力等级与百分比，另加 dispatch 事件补记一个采样间隔内的最差等级；
  - Swap；
  - 页入 / 页出、换入 / 换出、压缩 / 解压速率与压缩比；
  - 按内存的 Top N（按应用，可展开，可结束同 uid 进程）；
  - 历史。
- **菜单栏**：占用（出厂开；显示百分比或已用 GB）、压力、Swap。
- **只进诊断页**：DRAM 带宽（相对量）、MTE、ECC、引导占用、可执行与共享区页、页面队列核对。
- **划出**：每应用内存历史 → 应用活动。
- **不做**：
  - jetsam；
  - spawn `top`、`vm_stat`、`memory_pressure`（只有 CLI 的 `verify` 手动运行一次）；
  - 单列 purgeable；
  - 按数值着色。

## 3. 数据模型（`SysModel/MemoryMetrics.swift`，发布后不改名）

| MetricID | 单位 | 说明 |
|---|---|---|
| `memory.physical` | B | `hw.memsize` |
| `memory.used`、`memory.app`、`memory.wired`、`memory.compressed`、`memory.cached`、`memory.free` | B | §1.1 |
| `memory.usage` | ratio | 已用 ÷ 物理 |
| `memory.pressure` | ratio | 1 − `memorystatus_level` / 100 |
| `memory.pressure.level` | level | 1 / 2 / 4（`MemoryPressureLevel`） |
| `memory.swap.used`、`memory.swap.total` | B | `vm.swapusage` |
| `memory.compression.ratio` | × | 没有被压缩的页时不可用（`nothingCompressed`） |
| `memory.rate.{pageins,pageouts,swapins,swapouts,compressions,decompressions}` | 1/s | `host_statistics64` 差分 |
| `memory.bandwidth.{read,write}` | B/s | relative |

`TopNRow` / `TopNMember` 增加 `footprint`、`residualFootprint`（默认 nil，CPU Top N 不受影响）；新增 `TopNMetric`。

## 4. 采集层

### 4.1 `MemoryCollector`（`memory.vm`，inline）

- 自检：
  - 必需项：sysctl 可读；
  - 提示项：rev6、队列之和 ±3%、压力 sysctl 可读。
  - rev6 不过时，被压缩改用 `vm.compressor_bytes_used`（质量 estimated，已用随之 estimated），速率不可用。
- 陈旧：`host_statistics64` 的结果与上次逐字节相同时，staleCount + 1，不出速率，基线不动（CLAUDE.md）。M5 上 0.5 s 一次连采 12 次没有遇到陈旧；节流主要出现在多个进程密集调用时（调研报告 §0-7）。
- 计数回退：对应速率不可用（`counterReset`），不钳为 0。
- 压力事件：`DispatchSource.makeMemoryPressureSource` 在 utility 队列上记录最差等级，采样时与当前 sysctl 等级取较差者，然后清零。

### 4.2 `DRAMBandwidthCollector`（`memory.bandwidth`，inline）

- 启动自检只检查 libIOReport，不枚举组；第一次有需求时，按候选组 `PMP0` → `PMP` 找含「DCS BW」子组与 `AMCC RD` / `AMCC WR` 的那个。之后的复检照常重找。
- 状态名（「16GB/s」…）解析出各档上界，要求严格递增；按事件增量 × 档中点加权平均（`BandwidthHistogram`）。

### 4.3 Top N（`AppSampler` + `TopNBuilder.buildMemory`）

- `AppSampler` 每次扫描都留下全部有成员的 coalition 的 footprint（`latestFootprints`）。第一次扫描就有，不需要差分。
- 按应用：取 footprint 前 N 个 coalition。代表成员的规则同 CPU；同 uid 成员用 `ri_phys_footprint`；外部成员合计 = coalition 合计 − 同 uid 之和，钳到 ≥0。
- 按进程：拆成同 uid 成员，外部成员合成一个组行。
- 回退（coalition 不可用）：`SameUIDSampler.sampleMemory`，只列同 uid 进程；不提供「刷新全部」。

### 4.4 需求

| 消费者 | 采集器 | 间隔 |
|---|---|---|
| 菜单栏三个 widget | `memory.vm` | 内存模块常驻间隔（跟随全局，默认 1 s） |
| 面板内存 tab | `memory.vm` | 1 s |
| 面板内存 Top N | `app.coalition` | 设置，默认 5 s（可选 1/2/5） |
| 历史（background 层） | `memory.vm` | 10 s |
| 诊断页 | `memory.vm` 2 s；展开 DRAM 带宽时 `memory.bandwidth` 2 s | — |

## 5. 历史（schema 不变）

- `HistoryModule.memory`，由「记录内存历史」开关控制（默认开）。
- 入库：已用、占用率、App、联动、被压缩、已缓存、Swap 已用、压力、压力等级（instant，`B` / `ratio` / `level`），以及页入、页出、换入、换出（interval，`1/s`），每分钟 13 行。
- 不入库：物理、空闲、Swap 总量、压缩比、压缩 / 解压速率、带宽。

## 6. App 层

### 6.1 菜单栏

| widget | 小标签 | 数值 | 定宽依据 |
|---|---|---|---|
| `memoryUsage` | RAM（2026-10-16 由 MEM 改名）| 「64%」或「40.8G」 | 「100%」/「99.9G」 |
| `memoryPressure` | PRES | 「6%」 | 「100%」 |
| `swapUsed` | SWAP | 「0.0G」 | 「99.9G」 |

- GB 按 1024 换算，< 99.95 时保留一位小数，否则取整。
- autosaveName 为 `<bundle id>.memory.<widget>`；点击打开面板的内存 tab（D47）。

### 6.2 面板「内存」tab

依次为：

1. 概览：已用 GB（大字）、「共 64 GB · 占用 64%」；右栏为压力（等级 · 百分比）、Swap、被压缩。
2. 历史图：占用率，可叠加压力。
3. 构成：堆叠条加五行（App、联动、被压缩、已缓存、空闲），带占物理内存的比例。
4. 活动：三组速率与压缩比；压力徽标，另给「15 分钟内最高」等级（来自环形缓冲）。
5. Top N（按内存）。

每秒都在变的部分用 AppKit 自绘。

### 6.3 设置页「内存」（D41 分节）

- **菜单栏**：三个 widget；占用 widget 展开后可选「占用率 / 已用 GB」。
- **采集**：常驻间隔覆盖、面板 Top N 间隔（标注开销）。
- **面板**：Top N 行数与分组、图表跨度、叠加压力。
- **历史**：记录开关。

「菜单栏」页总览和「历史与导出」页也补上了内存的跳转。

### 6.4 诊断页

- 内存数据源：数据路径、rev6 与陈旧次数、队列之和比值、页大小、物理 / 可用、引导占用、可执行 / 共享区；ECC（注明未经验证）；MTE（只在有 `vm.mte.*` 时）。
- DRAM 带宽：折叠，展开时才登记需求。

## 7. 单实例（D48，同轮完成）

见 `docs/decisions.md` D48。实现：`SysStore/InstanceLock.swift`（flock）、`App/Support/SingleInstance.swift`；Debug 用 `--single-instance` 验证日用版规则。

## 8. 命令行

- `memory [--interval 1] [--count 5] [--bandwidth] [--json]`
- `memtop [--rows 10] [--count 1] [--by-process] [--fallback] [--json]`
- `verify memory`：与 `vm_stat`、`memory_pressure -Q` 对照。
- `verify memtop`：与 `top -l 1 -o mem` 对照，同一 pid。

## 9. 测试

- 单测（`MemoryTests.swift`、`MemoryHistoryTests.swift`）：
  - 活动监视器公式、回退估算、压缩比；
  - 速率与计数回退、陈旧判定、rev6 count；
  - 压力等级；
  - 带宽直方图的解析、拒绝与加权平均；
  - 入库规则。
- 硬件测试（`make test-hw`、`make remote-test`）：
  - 自检通过、已用 = 三项之和、队列之和 ±3%；
  - coalition footprint 降序，内存 Top N 有 5 行；
  - 带宽通道能发现、质量为 relative。

## 10. 开销测量

`make measure` 加了 `memory` 档（面板固定在内存 tab，Top N 5 行）；出厂默认档的说明改为三个 item（D51）。结果在 `docs/perf/memory.md`。

## 11. 偏离记录

- 2026-10-16：CPU 的 Top N 模型原来在每次 coalition 扫描后都组装，包括面板关闭时后台历史每 10 s 一次的扫描（组装约 1–3 ms，结果直接丢弃）。加内存 Top N 时一并改为只在所属 tab 可见时组装（`TopNModel.isActive`）。
- 2026-10-16：内存 Top N 默认 5 s 一次（CPU 为 2 s）。footprint 变化慢，coalition 全量扫描一次要 10–14 ms，2 s 会让面板档多出约 0.4% 单核。
- 2026-10-16：设置页 sidebar 的内存图标用 SF Symbol `memorychip`。
- 2026-10-16：压力警告 / 严重等级起初没法验证（D18 不用 sudo）。用户授权 D52 后，用 `sudo memory_pressure -S` 模拟两档各 20 s 验证通过，见验收报告第 8 项。
