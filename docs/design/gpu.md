# GPU 与加速器模块：能力边界（讨论稿）

> 日期：2026-10-16。§3 的 G1–G10 已由用户全部按推荐确认，见 `docs/decisions.md` D57–D59。§4 起是实现规格，§9 是偏离记录。
> 证据：`research/probes/gpu-module/`（2026-10-16，M5 Pro 与 M4 Pro 同步实测，macOS 27.0.1 26A434）；早期只在 M5 上测过的 `research/probes/gpu/`、`gpu-review/`（2026-09-28）。
> 「M5」「M4」分别指开发机 Mac17,16 与对照机 Mac16,11。

## 0. 测了什么

- **只读结构比对**（`gpu_struct.c`）：IOReport 中 GPU / 媒体引擎 / ANE 相关通道，pmgr DVFS 表，AGX 与 ANE 的 IORegistry 属性，SMC `Tg*` / `Ta*` 键，coalition 槽位 8 / 41 / 38 / 39。
- **负载实测**（`orchestrate.sh` + `gpu_watch.c`）：在一个完整的 30 分钟 PMGR 窗口里依次跑以下负载，每段不超过 60 s，段间空闲至少 60 s。`gpu_watch` 每秒记录一次，同时记下每个读取分段的线程 CPU：
  - GPU 满载（pipe 模式，同时 3 个命令缓冲在飞）；
  - 占空 25% / 50%；
  - 渲染；
  - CPU + GPU 同时满载；
  - ANE 4 线程 / 1 线程；
  - HEVC / H.264 编码，HEVC 解码，ProRes 编码；
  - 补测：单线程组规模的小 kernel（`tiny.sh`）。
- **真实节奏开销**（`costbench_gpu.c`）：每秒醒来一次，每次只读一项，取 30 轮的中位数。

## 1. 实测结果

### 1.1 结构：两台机器的同与不同

| 项 | M5 | M4 | 结论 |
|---|---|---|---|
| AGX 类 | `AGXAcceleratorG17X`，20 核，`num_mgpus=2` | `AGXAcceleratorG16X`，20 核，`num_mgpus=2` | 核数、分区数在运行时读 `GPUConfigurationVariable` |
| `GPUPH` 状态 | OFF + P1…P15（16 个） | 相同 | 通道名、状态名两台一致 |
| 实际用到的最高档 | P13 | P15 | 档数不能写死 |
| GPU DVFS 表 | `voltage-states9`：13 个非零档，338–1620 MHz，单调递增 | `voltage-states9`：15 个非零档，338–1578 MHz，**不单调**（…1182, 1182, 1312, 1242, 1380, 1326, 1470, 1578） | P*k* 取表中第 *k* 个非零频率。两台的最高档都与满载时的档位吻合；M4 中间几档的顺序没法验证（见 §2） |
| 其他 GPU 状态通道 | BSTGPUPH、GPU_CLTM、PWRCTRL、PZRSDNCY、GPUDVDH、GPU_PPM、PMU_RC… | 多出 `GPU_SW`（软件请求档位）和一组 `Temperature` 计数 | 见 §1.2 |
| `PerformanceStatistics` 键 | 两台相同（含 `In use system memory`、`Device Utilization %`） | 相同 | |
| ANE 节点 | `H11ANEIn`（h17，16 核）+ **`ANEExclaveProxy`** | `H11ANEIn`（h16g，16 核），**没有** Exclave 代理 | M5 的 ANE 在 Exclave 后面 |
| ANE 中断（`ane0`） | 订阅成功，但样本里**静默缺失** | 可读，ANE 4 线程负载时约 1315 次/s | 只能作 M4 的附加信号，不能作主路径 |
| 媒体引擎中断 | ave0 / avd0 / apr0 / jpeg0–1 / scaler0–1 | ave0 / avd0 / apr0 / jpeg0–1 / scaler0 | 两台都可读 |
| PMP 组 | `PMP0`；AF BW 有 AGX / ANE L0/L1 / AVD，**没有 AVE**（AVE 只在 SOC-NI） | `PMP`；AF BW 有 AGX / ANE0 L0/L1 / AVE0/1 / AVD0 | 组名、通道名都按运行时发现（同 D49 的 DCS BW） |
| Energy Model（PMGR） | `GPU0`、`ANE0`、`AVE0`、`AFR0`、`MSR0`、`ISP0`… | `GPU`、`GPU SRAM`、`ANE`、`AVE`… | 沿用 D44 的归一化 |
| SMC `Tg*` | 42 个，GPU 关断时也有真实读数（空闲约 45 °C） | 22 个，**GPU 关断时 87% 时间是占位值**（−4、0、2.2、2.4） | 见 §1.4 |
| SMC `Ta*` | 7 个，随 GPU、CPU、ANE 负载都升高 | 13 个，只在 ANE 上电时有读数（占位值 0、8.2） | |
| coalition 槽位 8 / 41 / 38 / 39 | 可读，非零 25 / 24 / 3 / 3 个 | 可读，非零 10 / 11 / 2 / 2 个 | 两台语义一致（§1.3） |

### 1.2 GPU 利用率：各来源对照（每段均值，去首尾 3 s）

「负载自报」是负载程序用 Metal 的 `gpuStartTime/gpuEndTime` 统计的忙碌比例。

| 段 | 负载自报 | GPUPH 活跃 M5 / M4 | 档位 M5 / M4 | GPU 功率 M5 / M4（W） | coalition 槽位 8 合计 M5 / M4 | `Device Utilization %` M5 / M4 |
|---|---|---|---|---|---|---|
| 空闲 | — | 6.4% / 0.0% | P1 / OFF | 0.04 / 0.00 | 3.7% / 0% | 0 / 0 |
| 满载（pipe） | 100% | 100% / 100% | P13 / P15 | 34.3 / 21.8 | **141%** / 100% | 100 / 0 |
| 占空 25% | 21.7% / 23.6% | **39.8%** / 26.4% | 多在 P13 / P1–P15 混合 | 6.5 / 1.4 | 26.8% / 23.6% | 62 / 67 |
| 占空 50% | 44.0% / 45.6% | **57.3%** / 50.2% | 同上 | 14.8 / 6.4 | 49.1% / 45.5% | 79 / 81 |
| 渲染 | 100% | 100% / 100% | P13 / P15 | 33.4 / 31.7 | 114% / 100% | 65 / 99 |
| CPU + GPU 满载 | 100% | 100% / 99.4% | 1600 / 1544 MHz | 34.8 / 21.3 | 139% / 100% | 100 / **8** |
| 小 kernel（256 线程） | 100% | 100% / 100% | P13 / P15 | **2.5 / 1.5** | 102% / 100% | 100 / **0** |
| ANE 4 线程 | — | **99.9%** / 77% | P1（338 MHz） | 0.44 / 0.21 | 4% / 1.4% | 0 / 0 |
| HEVC 编码 | — | 5.8% / 0% | P1 / OFF | 0.05 / 0.00 | 3.4% / 0% | 0 / 0 |

结论：
- **`Device Utilization %` 确认不可用**：M4 在 CPU + GPU 满载时读 8、小 kernel 时读 0、满载时读 0；占空 25% 时两台都读 60% 以上。
- **GPUPH 活跃**：满载、占空、关断这些情况都跟得上，但有两种偏差：
  - **M5 在低占空时偏高**：25% 占空读 39.8%，50% 占空读 57.3%。原因是 GPU 做完一批工作后还要上电一段时间才关断；M4 没有这个现象（26.4% / 50.2%）。
  - **「上电」不等于「在算」**：小 kernel 读 100%，但功率只有满载的 7%；ANE 推理时 M5 的 GPU 读 99.9%（338 MHz、0.44 W），推测是 Vision 的前处理让 GPU 一直开着。
- **coalition 槽位 8 合计**（各应用 GPU 时间之和 ÷ 墙钟）：占空时最接近负载自报，但在 M5 上，多个命令缓冲同时在飞（141%）或渲染（114%）时会超过 100%。可以截到 100% 来用，代价是要全量扫描 coalition（§1.5）。
- **频率**：两台满载都跑到最高档（M5 P13 = 1620 MHz，M4 P15 = 1578 MHz）。CPU + GPU 同时满载时降到 1600 / 1544 MHz。功耗与散热边界稿里观察到 M4 在这种情况下 GPU 功率会从 18.7 W 掉到 10.3 W，这次没有复现（21.3 W，GPU 段 45 s，比上次短）。M5 低占空时直接跑最高档（race to idle），M4 会在各档之间分散。
- **其他候选全部没有信息量**：
  - BSTGPUPH 恒为 100%；
  - GPUDVDH、GPU_PPM 恒为 100%；
  - GPU_CLTM、PZRSDNCY 在所有负载下都是 0（没触发过节流）；
  - UT Engagement 在 M5 上只有个位数，M4 上为 0；
  - M4 的 AGX `Temperature` 计数全是 0；
  - PWRCTRL 主状态只给原因码（DEADLINE / PRFBOOST / PERF / IDLE_OFF）。
  这些只适合放诊断页。

### 1.3 功率与能量：窗口对账（一个完整的 30 分钟 PMGR 窗口）

| 项 | M5 | M4 |
|---|---|---|
| AGX `GPU Energy` 积分 ÷ PMGR GPU 批次 | 4852.5 / 4843.8 J = **1.002** | 3128.1 / 3155.4 J = **0.991** |
| coalition 槽位 41 合计积分 ÷ PMGR GPU 批次 | **1.002**（与 AGX 逐焦耳相等） | **0.991**（与 AGX 相等） |
| coalition 槽位 39 合计积分 ÷ PMGR ANE 批次 | 186.6 / 203.0 J = **0.919** | 150.2 / 161.3 J = **0.931** |
| ANE 4 线程时的槽位 39 合计（W） | 3.68 | 3.06 |
| ANE 4 线程时的槽位 38 合计（按 mach tick 换算的忙碌比例） | 74% | 78% |

结论：
- GPU 功率继续用 AGX，D44 不变。各应用槽位 41 的合计与 AGX 逐焦耳相等，所以按应用分 GPU 能耗时，各应用之和就是整机 GPU 能耗。
- **ANE 准实时估算（K36 / D45 的遗留项）在两台上都对得上，偏低 7–8%**。偏低的部分推测是没有记到任何 coalition 上的 ANE 静态功耗。每台机器只测了一个窗口，比值是否稳定还要更多窗口确认。槽位 38 换算成忙碌比例后两台一致，而且不超过 100%，这间接印证「单位是 mach tick」。

### 1.4 温度

- M5：
  - 42 个 `Tg*` 键始终有真实读数：空闲约 45 °C，满载段末 72–80 °C，CPU + GPU 满载段均值 90.9 °C，单键峰值 100.8 °C。
  - `Ta*` 不只随 ANE 变化：GPU 满载段末 64.6 °C，ANE 段末 71 °C，CPU + GPU 满载段均值 82.8 °C。所以在 M5 上它不能当「ANE 温度」。
- M4：
  - GPU 关断时 `Tg*` 87% 的时间是占位值，只有 GPU 上电时才有读数；
  - 键**成对**出现：一个键的占位值是 −4，另一个是 2.4（或 0 / −4），上电后两者相差恒定的 6.4 °C（例如 `Tg04` 78.6 与 `Tg05` 85.0），或者完全相等（`Tg0K` 与 `Tg0L`）。这和 CPU 温度的「三元组变体」（D33）是同一类现象。
  - `Ta*` 也成对出现，相差 8.2 °C，只在 ANE 上电时有读数。
- 结论：
  - GPU 温度要像 D33 那样，由芯片档案决定代表变体和占位值；
  - M4 上 GPU 关断时没有 GPU 温度，显示「—」（数据质量：不可用）；
  - 「ANE 温度」两台都不能可靠命名（M5 混入了 GPU 和 CPU 的热，M4 只在上电时有读数），不建议进主界面。

### 1.5 ANE、媒体引擎

- **ANE 电源状态**（`H11ANEIn` `CurrentPowerState`）：两台一致，上电滞后 0.5–0.8 s，关断滞后 5.3–6.2 s。
- **ANE 活动强度**：PMP「AF BW」中的 ANE 通道（相对量）在两台上都有响应，4 线程时加权档位约 6.6，1 线程时约 1.9–2.3。
- **媒体引擎中断**，两台一致：

| 负载 | M5（每秒中断，帧率） | M4（每秒中断，帧率） | 关系 |
|---|---|---|---|
| HEVC 编码 | ave 141（70 fps） | ave 119（59 fps） | ≈ 2 × 帧率 |
| H.264 编码 | ave 146（73 fps） | ave 125（62 fps） | ≈ 2 × 帧率 |
| HEVC 解码 | avd 2168（639 fps） | avd 2183（667 fps） | ≈ 3.3 × 帧率 |
| ProRes 编码 | apr 733（730 fps） | apr 309（309 fps） | ≈ 1 × 帧率 |

  M5 的 avd **空闲时恒有约 90 次/s 的底数**（M4 为 0），判断是否在解码要减去底数。中断数能用来判断「编码 / 解码 / ProRes 是否在工作」和相对强度，但不同编码器的比例不同，不能换算成帧率。
- **媒体引擎功耗**：只有 PMGR AVE 批次（M5 窗口内 43 J，M4 24 J），继续只放「最近 30 分钟」卡片（D45）。

### 1.6 真实节奏开销（线程 CPU，每秒醒来一次；`costbench_gpu`，30 轮中位数）

| 读取项 | M5 | M4 | 每秒一次的单核占比 |
|---|---|---|---|
| GPUPH 单通道订阅 | 1.33 ms | 1.76 ms | 0.13–0.18% |
| AGX `GPU Energy` 单通道（功耗模块已有） | 1.34 ms | 1.54 ms | 0.13–0.15% |
| **两者合并成一个订阅** | **1.30 ms** | **1.60 ms** | 与单通道相同 |
| 全部 `Tg*` 键（42 / 22 个） | 1.34 ms | 1.97 ms | 0.13–0.20% |
| ANE 电源状态 + PerfStats（IORegistry） | 0.25 ms | 0.42 ms | 0.03–0.04% |
| 媒体引擎中断（ave/avd/apr） | 0.39 ms | 0.52 ms | 0.04–0.05% |
| PMP 带宽（`gpu_watch` 内测） | 3.8 ms | 7.8 ms | 0.4–0.8%，只适合诊断页 |
| coalition 全量扫描（`gpu_watch` 内测） | 4.1 ms | 6.3 ms | 已由 AppSampler 提供，不新增 |

要点：
- IOReport 每次采样的开销主要是醒来后第一次调用的固定成本（D34 里也观察到），和通道数关系不大。所以 GPUPH 应该**并进 AGX `GPU Energy` 的同一个订阅**：GPU 活跃率和功率一起读，成本和现在只读功率一样。
- 温度要在每秒读全部 `Tg*` 和只读档案指定的少数键之间取舍。按每键约 30–90 µs 估算，只读 4 个键约 0.2–0.4 ms。
- 都按 D40 的口径记录。正式开销在实现后由 `make measure` 测。

## 2. 跨芯片差异与未验证项

- M4 DVFS 表中间几档不单调，P*k* 到频率的映射只在最低档和最高档有负载验证，中间档没验证。所以面板的「平均频率」只按驻留加权估算，并在诊断页列出原始档位驻留。
- M5 在低占空时 GPUPH 偏高（§1.2）。这是 M5 的关断滞后，不是读数错误，但会让「GPU 活跃」在轻负载时看起来比 M4 高。
- ANE 估算的比值（0.92 / 0.93）每台只有一个窗口。
- 只有两台台式机。M4 没接显示器，所以空闲时 GPU 完全关断；M5 接了显示器，空闲时有约 6% 的活跃率。笔记本和其他芯片没测（D20）。

## 3. 需要拍板的事项

### G1 GPU 主指标的来源与名称
- **A（推荐）**：GPUPH 非 OFF 驻留，命名「GPU 活跃」，旁边总配功率和频率。和功率读同一个订阅，常驻基本不增加开销。说明里写明「上电时间，不是算力占用」，M5 轻负载时偏高。
- **B**：coalition 槽位 8 合计截到 100%，命名「GPU 占用」。占空时更准，但每秒全量扫描 coalition 要 4–6 ms（比 A 贵 3–4 倍），常驻会超出出厂预算。M5 多命令缓冲时会超过 100%，靠截断掩盖。
- **C**：A 作主指标，B 只在面板可见时作副行（「按应用合计」），反正面板的 Top N 本来就在扫 coalition。
- 「频率加权」（活跃 × f / f_max）不建议：小 kernel 和 ANE 前处理的例子说明，真正能区分负载轻重的是功率，而不是频率。

### G2 频率
- **A（推荐）**：面板显示 GPU 活跃期间的平均频率（按驻留加权，档位表在运行时按 GPUPH 状态数配对 DVFS 表）。诊断页列各档驻留。同一个订阅里顺带算出，不额外采样。
- **B**：只在诊断页显示。

### G3 菜单栏 widget 与出厂默认
- **A（推荐）**：GPU 活跃、GPU 功率、GPU 温度三个 widget，**出厂全关**（D51）。GPU 功率 widget 从功耗模块移到 GPU 模块页（D41：一个设置只有一处可编辑），功耗页里只读引用；数据源不动。频率 widget 不提供。
- **B**：同 A，但 GPU 功率 widget 留在功耗模块。

### G4 GPU 温度
- **A（推荐）**：芯片档案指定代表键集与占位值（像 D33 那样由实测生成）：M5 选每个分区最热的 2 个键，M4 每对取一个代表变体。显示这些键的最大值；M4 上 GPU 关断时显示「—」。未知芯片读全部 `Tg*`，去掉占位值后取最大值，标「学习中」。
- **B**：每次读全部 `Tg*` 取最大值（每秒多 1.3–2.0 ms），不做档案。M4 的成对键会让读数取到偏高的那一个变体（+6.4 °C）。
- 「ANE 温度」不进主界面（§1.4），只在诊断页的传感器目录里按 D44 的规则列出。

### G5 ANE
- **A（推荐）**：面板显示 ANE 开 / 关（注明关断滞后约 5–6 s），以及「ANE 功率（估算）」= 槽位 39 合计，数据质量标「估算」。面板可见时跟随 Top N 的 coalition 扫描，不常驻、不进菜单栏。诊断页每个 PMGR 窗口记录一次槽位 39 合计 ÷ ANE 批次的比值，连续偏离 0.8–1.05 时隐藏估算值。
- **B**：先只显示开 / 关，估算值等多积累几个窗口再上线（K36 的原推荐）。

### G6 媒体引擎
- **A（推荐）**：面板可见时订阅 ave / avd / apr 中断（0.4–0.5 ms/次），显示「编码 / 解码 / ProRes：活动 / 空闲」加相对强度条，avd 减去空闲底数（运行时学习）。不显示帧率和瓦数，不提供 widget。瓦数仍只在「最近 30 分钟」卡片里。
- **B**：只在诊断页显示。

### G7 Top N
- **A（推荐）**：GPU 面板有 Top N，按应用（D31 的分组）按槽位 8 的 GPU 时间排序，列出 GPU 时间占比、GPU 能耗（槽位 41 → W）、ANE 能耗（槽位 39 → W）。只在 GPU 面板可见时采样，复用 AppSampler。每应用的历史留给应用活动。
- **B**：不放 Top N，留给应用活动模块。

### G8 GPU 内存
- **A（推荐）**：面板显示 `In use system memory` / `Alloc system memory`，标「GPU 占用的统一内存」。0.25–0.42 ms，面板可见时读。
- **B**：不显示。

### G9 历史
- **A（推荐）**：GPU 活跃、GPU 功率（已有）、GPU 温度、ANE 是否上电（按分钟统计上电秒数）进历史库。面板关闭时 background 层每 10 s 采活跃率和温度（活跃率是累计驻留，10 s 一读不丢平均值），功率沿用现有节奏。
- **B**：只记活跃率与功率。

### G10 只放诊断页的内容（无须拍板，列出供确认）
各档驻留、平均档位、PWRCTRL 原因码、GPU_CLTM / PZRSDNCY 节流驻留、PMP 带宽（AGX / ANE / AVE / AVD，展开时才订阅）、M4 的 ANE 中断、`Device Utilization %` 原值（标「不可靠，仅供对照」）、ANE 估算对账比值。

### 不做
FPS、显示器列表（D13 范围里没有使用者）；`Device Utilization %` 作任何主指标；按 pid 的 AGX `AppUsage`（会高估，且与 coalition 重复）；给媒体引擎估算实时瓦数。

## 4. 数据模型（`SysModel/GPUMetrics.swift`，发布后不改名）

| MetricID | 含义 | 单位 / 质量 | 采集器 |
|---|---|---|---|
| `gpu.active` | GPUPH 非 OFF 驻留比例 | 0…1，measured | `power.gpu` |
| `gpu.frequency` | 活跃期间的平均频率（驻留加权） | Hz；档案表 measured，推断表 inferred；GPU 全程关断时 unavailable(`deviceIdle`) | `power.gpu` |
| `gpu.temperature` | 代表键有效读数的最大值 | °C；档案 measured，未知芯片 inferred；全是占位值时 unavailable(`sensorPowerGated`) | `gpu.temperature` |
| `ane.powered` | ANE 是否上电 | 0 / 1 | `gpu.accelerators` |
| `gpu.memory.inUse` / `gpu.memory.allocated` | AGX `PerformanceStatistics` | B | `gpu.accelerators` |
| `ane.power.estimated` | 全部 coalition 槽位 39 差分合计 ÷ 墙钟 | W，estimated；对账连续失败时 unavailable | `app.coalition`（汇总样本） |
| `media.encode.rate` / `media.decode.rate` / `media.prores.rate` | ave / avd / apr 一级中断，减去学到的空闲底数 | 次/秒，relative | `gpu.media` |

`power.gpu`（GPU 功率）继续由功耗模块定义，GPU 模块复用。

## 5. 采集器

- **`power.gpu`（改）**：订阅从「AGX `GPU Energy`」一个通道扩成「`GPU Energy` + `GPU Stats / GPUPH`」两个通道（同一 AGX 驱动，合并订阅，§1.6）。每次采样同时输出 `power.gpu`、`gpu.active`、`gpu.frequency`。自检新增 `power.gpu.gpuph`（找到 GPUPH 且状态名首个为 OFF）与 `power.gpu.dvfs`（档位表，advisory）。GPUPH 缺失时只影响活跃与频率，功率照常。诊断读数：最近一次各档驻留、平均档位、档位表来源。
- **`gpu.temperature`（新，阻塞通道）**：读档案 `gpu.temperatureKeys`，占位值与合理范围取档案 `gpu.sentinels` / `gpu.validRange`。没有档案时自检枚举全部 `Tg*`（flt），占位值用 `[-4, 0, 2.2, 2.4]` 加「< 10 °C」。
- **`gpu.accelerators`（新，inline）**：IORegistry 读 `H11ANEIn` 的 `IOPowerManagement.CurrentPowerState` 与 AGX 的 `PerformanceStatistics`（0.25–0.42 ms）。找不到 ANE 节点的芯片不输出 `ane.powered`。
- **`gpu.media`（新，inline）**：IOReport「Interrupt Statistics (by index)」组，子组名以 `ave`、`avd`、`apr` 开头（后跟空格与序号）、通道名「First Level Interrupt Handler Count」的通道。每个引擎的空闲底数 = 最近 120 个样本的最小值（样本不足 10 个时为 0），输出减去底数后的速率（钳到 ≥0）。
- **`gpu.diagnostics`（新，inline，只在诊断页展开「GPU 细节」时有需求）**：GPU Stats 的 PWRCTRL / GPU_CLTM / PZRSDNCY，PMP 组（运行时按「`PMP` 前缀 + 子组 AF BW」发现）里 AGX / ANE / AVE / AVD 的 RD+WR 加权档位，ANE 中断（`ane0` 子组，M5 上缺失），`Device Utilization %` 原值。
- **`app.coalition`（改）**：增量里加 GPU 时间（槽位 8，ns）、GPU 能耗（41）、ANE 时间（38，mach tick → ns）、ANE 能耗（39）。汇总样本加 `ane.power.estimated`；每个窗口的槽位 39 合计记进账本（`PowerLedger.recordANE`）。
- **`power.pmgr`（改）**：批次到来时加一项 `ane` 核对：账本里批次窗口内的 ANE 积分 ÷ PMGR ANE 批次，范围 0.8–1.05，最低窗口均值 0.05 W，覆盖 ≥90%。

## 6. 芯片档案（`gpu` 段，可选）

```json
"gpu": {
  "dvfsTableKey": 9,
  "temperatureKeys": ["Tg3B", "Tg1o", "Tg3Z", "Tg3x", "Tg12"],
  "sentinels": [-4, 0, 2.2, 2.4],
  "validRange": [10, 130],
  "note": "…"
}
```

- M5：`Tg3B`、`Tg1o`、`Tg3Z`、`Tg3x`、`Tg12`。M4：`Tg1U`、`Tg1k`、`Tg0j`、`Tg1c`、`Tg0K`（成对键中的较低变体）。
- 选法：按 2026-10-16 实测（`out/*/gw_*_temps.csv`），贪心加键，直到「选中键最大值」与「全部有效键最大值」逐秒之差的 p95 为 0，最大差 ≤0.2 °C。M4 成对键先剔除较高的一侧（+6.2 / +6.4 °C）。

## 7. 历史

- `gpu.active`、`gpu.temperature`、`ane.powered`（分钟均值即上电比例）进历史库，模块 `gpu`。后台每 10 s 采 `power.gpu`、`gpu.temperature`、`gpu.accelerators`。
- 设置「记录 GPU 与加速器历史」默认开。

## 8. App

- **菜单栏**：`gpuActive`（「GPU 23%」）、`gpuPower`（从功耗模块移来，标签与样式不变）、`gpuTemperature`（「GPU 61°」）。三个都属于 `MenuModule.gpu`，出厂关。已有用户的 `menubar.power.gpuPower.*` 偏好键照旧读取，不迁移键名。
- **面板**（`PanelTab.gpu`）：概览（活跃大字 + 频率、功率、温度）→ 历史图（活跃，可叠加功率）→ 加速器卡片（ANE 开 / 关与估算功率、媒体引擎三行活动强度、GPU 内存）→ Top N（按 GPU 时间）。需求：面板可见时 `power.gpu` 1 s，`gpu.temperature`、`gpu.accelerators`、`gpu.media` 按「面板：温度与加速器」间隔（默认 2 s），Top N 按自己的间隔（默认 2 s）。
- **设置页**「GPU 与加速器」：菜单栏（3 个 widget）、采集、面板（Top N 行数与分组、图表跨度、叠加功率）、历史。功耗与散热页的菜单栏节去掉 GPU 功率，加一行「GPU 功率 widget 在『GPU 与加速器』页」的链接。
- **诊断页**「GPU 与加速器」：数据路径与档位表来源、各档驻留、温度键来源、ANE 对账比值；「GPU 细节」折叠组展开时才采 `gpu.diagnostics`。
- **CLI**：`sysinfo-cli gpu [--count N] [--interval S]`，逐秒打印活跃、频率、功率、温度、ANE、媒体引擎、GPU 内存；`--diag` 另打印细节通道。

## 9. 偏离记录

（实现中出现的偏离按日期追加于此。）

## 附：复现

```
research/probes/gpu-module/build.sh <outdir>          # 编译探针与负载（负载源码在 power-thermal/、gpu/、gpu-review/）
<outdir>/gpu_struct                                   # 结构比对
<outdir>/orchestrate.sh <outdir> <tag>                # 30 分钟 PMGR 窗口内的负载序列（每段 ≤60 s）
<outdir>/tiny.sh <outdir> <tag>                       # 小 kernel 补测
<outdir>/costbench_gpu 30                             # 真实节奏开销
python3 research/probes/gpu-module/analyze.py <dir> <tag> <P1..Pn 频率 MHz>
```

原始输出（`out/`）含本机标识，按 `.gitignore` 只留在本地。
