# CPU 模块实现规格

> 日期：2026-10-15 · 分支：`module/cpu`
> 依据：D14（完整版的内容）、D15、D19、D20、D24、D28（目标设备）、**D29–D34（本模块的边界与各项拍板）**；能力边界的论证和实测数据见 `docs/design/cpu-module-boundary.md`（下称「边界稿」），本文只写怎么实现。
> 与决策档冲突时以决策档为准。实现中必须偏离本文的地方，记在文末「偏离记录」里，写明日期、内容和原因。

## 1. 目标与验收

CPU 模块按 D14 做到完整版：采集器与自检回退、测试、菜单栏 item、完整的 CPU 面板（历史图表、Top N）、设置页，以及数值对照和开销实测。按 D29，本模块同时建立后续模块共用的基础设施：私有 C 层、IOReport hub、SMC 只读层、芯片档案、AppSampler（coalition）、历史库。

验收清单（两台目标机都要做，D28：M5 Pro 开发机、M4 Pro 对照机）：
1. `make build`、`make test`、`make test-hw` 通过，Swift 6 零警告。`make remote-test` 在对照机上通过。
2. 拓扑：
   - M5 显示 3 簇、2 档（超级核 ×6、性能核 ×12）；M4 显示 3 簇、2 档（性能核 ×10、能效核 ×4）。
   - 诊断页三种档次依据一致，状态 ok。
3. 频率：
   - 每簇实际频率与内核按档的 cycles/时间（`sysinfo-cli verify freq`，§8）对照，误差 ≤1%。
   - 簇空闲时显示「空闲」。
4. 温度：
   - 两台首次启动就按芯片档案显示 P 簇温度（M5 三个簇，M4 两个 P 簇）。
   - 空闲断电时显示「—」，不显示 40 °C。
   - E 簇没有温度行（D33）；诊断页能看到「E 簇附近」的读数。
5. 功耗：
   - 两台按簇显示 CPU 实时功耗。
   - GPU 负载、CPU 空闲时，各簇功耗不随 GPU 上升。
   - 把芯片档案换成一个不存在的芯片时，功耗显示「不可用」，不估算。
6. Top N：
   - 与 setuid `ps` 的 TIME 差分对照（`sysinfo-cli verify topn`），前 10 名误差 ≤0.5 pp。
   - 结束进程只对同 uid 进程可用。
   - coalition 自检被人为判失败时，回退到只显示同 uid 进程，并提供「刷新全部」按钮。
7. 历史：
   - 面板 1 时、24 时、7 天跨度能画出来。
   - 面板关闭、锁屏期间，分钟级数据照常写入。
   - 导出 CSV 和 JSON Lines，内容不含设备唯一标识。
8. 菜单栏：默认是上下布局的 CPU item，宽度固定；高占用时按 D32 变色。截图自查两台的效果。
9. 开销：`make measure` 在两台上实测出厂默认配置（常驻）和 CPU 面板打开两档，分别低于 0.5% 和 2% 单核（D19），结果写入 `docs/perf/cpu.md`。
10. 跨机：`make remote-cli ARGS=…` 在对照机上跑通全部子命令；验收报告附两台机器的对照表。

## 2. 仓库布局（新增与改动）

```
Packages/SysKit/
  Package.swift                       新增 SysStore target 与 product；SysCollectors 增加资源 ChipProfiles/
  Sources/CSysPrivate/
    include/CSysPrivate.h             声明 IOReport、SMC、coalition、PROC_PIDTHREADCOUNTS 等私有符号（弱链接）
    ioreport.c  smc.c  coalition.c  thread_counts.c
  Sources/SysModel/
    CPUMetrics.swift                  本模块的 MetricID
    CPUTopology.swift                 拓扑值类型（簇、档、核）
    ChipProfile.swift                 芯片档案的 Codable 结构
    ProcessGroup.swift                Top N 的值类型
  Sources/SysCollectors/
    Private/                          私有层的 Swift 封装：IOReportHub、SMCReader、CoalitionReader…
    Topology/                         TopologyDiscovery 与三种档次判定
    CPU/                              CPULoadCollector（扩展）、CPUFrequencyCollector、CPUMiscCollector、InterruptDeviceCollector
    Sensors/                          SensorCollector（温度 + 功耗）、TemperatureAttribution、RailAttribution、Calibration
    Apps/                             AppSampler（coalition）、TopNBuilder、ProcessKiller、PSFallback
    Profiles/                         ChipProfileStore（内置档案 + 本机校准缓存）
    Resources/ChipProfiles/*.json     内置芯片档案（AppleT6050 = M5 Pro，AppleT6041 = M4 Pro，AppleT6021 = M2 Max 旁证）
  Sources/SysStore/                   历史库：HistoryStore、MinuteAggregator、Exporter
  Sources/sysinfo-cli/                新增 topo / freq / sensors / topn / verify / calibrate / history 子命令
  Tests/SysStoreTests/                新增
App/
  MenuBar/                            CPUStatusItemView 改为可选样式（上下 / 左右 / 折线 / 柱状）
  Panel/CPU/                          概览、历史图、核心、详情、Top N 各一个视图
  Settings/                           CPU 页扩展；历史与导出页、隐私页补内容
  Diagnostics/                        数据源路径、芯片档案、传感器校准
docs/perf/cpu.md                      本模块的开销实测
```

- 仍然只对 app 暴露 library product，新增 `SysStore`。`SysStore` 不依赖 `CSysPrivate`。`scripts/check-private-imports.sh` 的检查范围加上 `Sources/SysStore`（D26）。
- 芯片档案是不含设备唯一标识的 JSON：只有 SoC 标识、键名、簇键和数值范围（CLAUDE.md「设备唯一标识不进版本库」）。

## 3. 私有 C 层（CSysPrivate，D05、D23、D26）

- 头文件只声明符号，并用 `__attribute__((weak_import))` 弱链接。C 文件里只做薄封装：调用、检查返回值、把结果拷进调用方提供的缓冲区。业务逻辑一律放在 Swift 层。
- `csp_layer_version()` 从 0 升到 1，以后每次增删符号都递增。
- 每组符号都提供 `csp_<组>_available()`，在运行时检查弱链接是否解析到。
- 声明的符号：
  - **IOReport**（libIOReport）：`IOReportCopyChannelsInGroup`、`IOReportMergeChannels`、`IOReportCreateSubscription`、`IOReportCreateSamples`、`IOReportCreateSamplesDelta`、`IOReportChannelGetGroup`、`IOReportChannelGetSubGroup`、`IOReportChannelGetChannelName`、`IOReportChannelGetChannelID`、`IOReportStateGetCount`、`IOReportStateGetNameForIndex`、`IOReportStateGetResidency`、`IOReportSimpleGetIntegerValue`。
  - **SMC**：AppleSMC 用户客户端的结构体（`SMCKeyData` 等）。读写走的是同一个 selector（2），区别只在命令字节，所以只声明三个读命令：`kSMCReadKey`、`kSMCGetKeyInfo`、`kSMCGetKeyFromIndex`。**不声明写命令 `kSMCWriteKey`**，封装函数也只接受这三个命令，传入其他命令一律拒绝。这样 D18 的「不写 SMC」由代码结构保证，并有单测覆盖。
  - **coalition**：`proc_listcoalitions`、`coalition_info_resource_usage`、`coalition_info_pid_list`。运行时用 dlsym 解析，解析不到即自检 S1 失败（边界稿 §7.4）。
  - **线程按档计数**：`proc_pidinfo` 的私有 flavor 34（`PROC_PIDTHREADCOUNTS`）。只给 `sysinfo-cli verify` 和自检被动校验用，不进常规采样。
  - **唯一标识**：`PROC_PIDUNIQIDENTIFIERINFO`（flavor 17），给 Top N 的名称缓存做键用（边界稿 §7.4）。

## 4. 数据模型（SysModel）

### 4.1 拓扑
```swift
struct ClusterKey: Hashable, Codable, Sendable { var die: UInt32; var cluster: UInt32 }   // 字符串形式 "d0c1"
struct CPUCluster  { key: ClusterKey; cpus: [Int]; classKey: String /*compatible+cluster-type，不透明*/; perfLevel: Int? }
struct PerfLevel   { index: Int; name: String /*hw.perflevelN.name 原文*/; cpuCount: Int; clusters: [ClusterKey] }
struct CPUTopology {
    var logicalCPUCount: Int
    var clusters: [CPUCluster]
    var perfLevels: [PerfLevel]            // 档次判定 degraded 时为空
    var quality: TopologyQuality           // .ok / .clustersOnly(reason) / .coresOnly(reason)
}
```
- 拓扑是一个值。启动、唤醒、build 变化时重新发现，变化时通知订阅者（app、历史库的 epoch）。
- `classKey` 只拿来比较是否相同，不解释其中字母的含义（CLAUDE.md：不按 E/M/P 字母猜核类型）。

### 4.2 MetricID（发布后不改名）

| MetricID | 单位 | 说明 |
|---|---|---|
| `cpu.usage.total`、`cpu.usage.core.<n>` | 0…1 | M0 已有 |
| `cpu.usage.user`、`cpu.usage.system` | 0…1 | 整机 |
| `cpu.usage.cluster.<d0c1>` | 0…1 | 每簇平均 |
| `cpu.usage.perflevel.<i>` | 0…1 | 每档平均；拓扑为 `.clustersOnly` 时不出 |
| `cpu.freq.cluster.<d0c1>` | Hz | 实际频率，按活跃驻留加权；簇空闲时出 `unavailable(clusterIdle)`，UI 显示「空闲」 |
| `cpu.temp.cluster.<d0c1>` | °C | 簇内已归簇键的最大值（代表变体）；只给有温度行的簇 |
| `cpu.temp.max` | °C | 所有 P 簇已归簇键的最大值（D33：不含 E 簇附近读数） |
| `cpu.power.cluster.<d0c1>` | W | 簇专用轨之和；没有专用轨时为 `unavailable(noDedicatedRail)` |
| `cpu.power.total` | W | 各簇之和；任意一簇不可用时整体不可用，不拿部分和充数 |
| `cpu.thermal.state` | 0…3 | nominal / fair / serious / critical |
| `cpu.loadavg.1`、`.5`、`.15` | — | `getloadavg()` |
| `cpu.tasks`、`cpu.threads` | 个 | `processor_set_statistics(PROCESSOR_SET_LOAD_INFO)` |
| `cpu.irq.ipi`、`cpu.irq.timer`、`cpu.irq.other` | 次/s | `PROCESSOR_CPU_STAT64` 的差分 |

- 请求频率、逐核频率、E 簇附近温度、每个温度键的原始值不定义为 MetricID：它们只进诊断页（`DiagnosticReading`，不入历史库）。
- 新增 `UnavailableReason`：`clusterIdle`、`noDedicatedRail`、`sensorPowerGated`（断电占位值）、`learning`（归簇学习中）、`notAttributed`。

### 4.3 芯片档案（D33）
```swift
struct ChipProfile: Codable {
    var schema: Int                        // 从 1 起
    var socID: String                      // PMGR 驱动类名，如 "AppleT6041PMGR"；主键
    var description: String                // "M4 Pro (Mac16,11)"，只作说明
    var verifiedBuilds: [String]           // 已验证的系统 build
    var source: String                     // 哪台机器、哪天、哪个校准或探针生成的
    var topology: TopologyExpectation      // nperflevels、每档核数、簇数、簇键 → perflevel（只作核对）
    var frequency: [ClusterKey: FreqDomain] // pmgr 表键、单位、表长、表顶（只作核对）
    var temperature: TemperatureProfile
    var power: PowerProfile
}
struct TemperatureProfile {
    var clusterKeys: [ClusterKey: [String]]   // 代表变体（x1）
    var aliasGroups: [[String]]               // 恒等或恒定偏移
    var peakKeys: [ClusterKey: [String]]      // x2，只进诊断页
    var aggregates: [String: [String]]        // 聚合键 → 覆盖的键
    var excluded: [String]                    // 非 CPU 键，例如 M5 的 Tm1p、M4 的 Tp1*/Tp2*
    var nearbyOnly: [ClusterKey: [String]]    // 只进诊断页的「附近」读数，例如 M4 的 E 簇 Te*
    var sentinels: [Double]                   // 断电占位值，例如 [40.0, -4.0, 0.0]
    var validRange: ClosedRange<Double>
}
struct PowerProfile { var clusterRails: [ClusterKey: [String]]; var gpuRails: [String]; var sharedRails: [String] }
```
- 档案的取值全部来自实测（D33）：M5 来自边界稿 §2.3，M4 来自 §9.2、§9.3；M2 的档案只作旁证和测试素材（D28）。
- 档案先按 `socID` 匹配。匹配不到就是「未知芯片」，走纯被动学习（§5.4）。

## 5. 采集层（SysCollectors）

### 5.1 引擎扩展：阻塞通道
- SMC 读取是阻塞的（M5 一次约 12–15 ms 墙钟，M4 全量 60–75 ms），coalition 冷态也要 7 ms 左右，不能拖慢 1 s 的占用采样。
- 采集器协议加一个属性 `lane: CollectorLane`，取值 `.inline`（默认）或 `.blocking`。
  - `.blocking` 的采集器在引擎的第二条私有串行队列上执行，和主 tick 并行。
  - 结果以同一个 tick 序号、同一个 `SampleTime` 单独交付一次：`EngineEvent.tick` 里的 `TickResult` 增加 `lane` 字段。
  - 如果上一次的阻塞采样还没结束，本 tick 跳过该采集器，计入 `skippedBusy`，在诊断页显示。
- 到期计算、降频、暂停、需求层级的语义都不变（M0 设计 §5.2）。仍然只有一个合并 tick 网格（D12、D19）。
- 采样线程保持 utility QoS（D29：提高 QoS 不省开销）。

### 5.2 TopologyDiscovery（边界稿 §7.1）
- 读 `IODeviceTree:/cpus`，得到 logical-cpu-id → (die-id, cluster-id)、`compatible`、`cluster-type`、`l2-cache-size`。
- 四处核数交叉校验：DT、`hw.logicalcpu_max`、`host_processor_info`、IOReport 逐核通道数。不等时 `.coresOnly`。
- 三种「类别 → perflevel」依据：数量、DVFS 表顶、L2 大小。每种只在构成完整一一对应时才算有效；**三种都求出来后两两核对，任何冲突都标 `.clustersOnly`**。不照搬参考实现 `topo_discover.h` 那种「取第一个有结果的」做法（边界稿 §2.1 复核修正）。
- 运行时用 rusage v6 的 `ri_*_ptime` 被动核对映射：本进程按档时间占比与按映射算出的占比偏差持续 >5 pp 时，标 degraded，并触发复检。
- 有单测：用合成输入（M1 4+4、M1 Ultra 双 die、三档芯片、依据冲突、核数不等），从 `assign_sim.c` 和 `sk_conflict.c` 移植过来。

### 5.3 CPULoadCollector（扩展 M0 的 `cpu.load`）
- 同一次 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` 读数，额外输出 user/system、每簇、每档。
- 每簇、每档按「拓扑当前值」聚合；拓扑变化时重建 MetricID 缓存，并丢弃一次差分。
- 陈旧判定、计数器回退按复位处理等规则不变（M0）。

### 5.4 CPUFrequencyCollector（`cpu.freq`，边界稿 §7.2）
- **IOReportHub**：全 app 共享的单例，惰性地对每个组只调一次 `IOReportCopyChannelsInGroup`，缓存通道字典（首次约 62 ms，之后每次约 28–31 ms，所以只枚举一次）。
  - 同一驱动的组合并进一个订阅；不同驱动的组分开订阅、按需启停（D34）。
  - 本模块用到两个订阅：「CPU Stats」的 CPM 订阅（频率），以及「Interrupt Statistics」订阅（中断来源，只在展开时启用）。
- 通道识别按结构规则（边界稿 §7.2 第 1–4 步），不按名字：
  - 逐核通道按出现顺序对应 logical cpu；
  - 请求簇通道取「本簇逐核通道名的最长公共前缀」；
  - 实际簇通道满足：状态名与请求通道相同、名字等长且只差一个字符、不是任何逐核通道名的前缀。
- DVFS 表：`perf-domains` 域名 → 表键 → `voltage-states<k>-sram`。单位按量级判断（M2 是 Hz，M4、M5 是 kHz）。合法性检查：严格递增、没有常数列、没有 0 档、表顶在 500–10000 MHz。
- 输出每簇实际频率。找不到实际通道时退回请求通道，质量标 `estimated`，诊断页注明「请求频率」。请求通道多核时偏高 7–17%，所以请求频率只在诊断页显示（D29）。
- 驻留是积分量，采样间隔多长都不丢平均值。面板默认 5 s，后台历史 60 s（D29）。
- 自检（边界稿 §7.5）：
  - 结构判据：表合法；簇通道恰好覆盖本簇的核；驻留增量之和 / 墙钟落在 timebase 频率的 0.97–1.02 倍。
  - 主动判据：启动、唤醒、build 变化时，采样线程自旋约 50 ms，用本线程的 `ri_cycles` / CPU 时间比对实际通道，阈值 ±5%。这一项只能验证 perflevel0 的表。
  - 被动判据：某档自然忙碌 >50% 的窗口里，用 coalition 全量求和得到的按档 cycles/时间比对实际通道，阈值 ±3%；同时要求每核 tick 忙碌% 与逐核通道活跃% 的相关系数 ≥0.99。被动判据用来发现「把请求通道误当成实际通道」的错误。

### 5.5 SensorCollector（`cpu.sensors`，`.blocking` 通道；温度 + 功耗）
- **SMCReader**（独立 actor 持有的连接）：
  - 启动时全量枚举，key-info 按系统 build 缓存到 Application Support（`.dev` 与 Release 隔离，D16）。
  - 字节序按属性位判断；支持 `flt`、`ioft`、`si32`、`sp78`、`ui8/16/32` 等类型；检查 result 字节。
  - 常规采样只读档案里的最小键集：M5 约 56 个温度键加 4 个功耗键；M4 约 40 个温度键加 6 个功耗键。
- **温度**：
  - 每个键先过占位值过滤：等于档案 `sentinels` 中的值即为无读数（`sensorPowerGated`）；未知芯片用启发式判定，即「连续 ≥10 次精确等于同一个整数值，而同组其他键在变化」。
  - 别名组内只取代表变体；簇温度 = 本簇代表变体里有效读数的最大值；本簇全部无读数时出 `unavailable(sensorPowerGated)`，UI 显示「—」。
  - `cpu.temp.max` 只取 P 簇已归簇的键（D33）。E 簇的 `nearbyOnly` 键只作为诊断读数输出。
  - x2（峰值组）只进诊断页。
- **功耗**：
  - 簇功耗 = 档案 `clusterRails` 之和，质量 `measured`。没有专用轨（档案里没有，或未知芯片尚未学到）时为 `unavailable(noDedicatedRail)`，**不估算**（D29）。
  - 运行时被动核对：GPU 负载窗口里簇轨增量必须约等于 0（GPU 轨由档案 `gpuRails` 读出）；违反时把该簇功耗标为不可用，并触发复检。
- **归簇学习**（TemperatureAttribution、RailAttribution，供未知芯片使用，也用于对已知芯片做被动校验）：
  - 温度的自变量是每簇功率（有专用轨时）或每簇占用（1 s 滞后、τ ≈ 1.5 s 平滑），加上 GPU 功率；做非负最小二乘。
  - 判入条件：R² ≥ 0.5、归一化贡献 ≥ 0.6、领先第二簇 ≥ 0.25、有足够的独立激励、GPU 贡献 < 0.65 × 该簇贡献（边界稿 §7.3 第 6 步）。
  - 学习结果与档案冲突时，该簇隐藏温度行、只保留 CPU 最高温，诊断页标「冲突」（D33）。
  - 功耗轨学习：与某簇占用强相关、对 GPU 负载无响应的轨，判为该簇的专用轨。
- **传感器校准**（Calibration，D33）：
  - 只在用户于诊断页点击后运行。先弹窗说明「约 50 s，期间 CPU 满载」，用户确认才开始。
  - 负载放在本进程内，按簇翻转：M4 用 ui10↔ui14（翻转 E 簇）和 ui5↔ui10（P 簇方波）；M5 用 ui12↔ui18。总时长不超过 60 s，段间穿插空闲（D18 的口径同样适用于产品功能）。
  - 结果按「socID + 系统 build」缓存，覆盖被动学习的结果。可以导出成档案 JSON，方便把新芯片的档案提交进仓库（§8 的 `calibrate --emit-profile`）。
- 采样间隔：面板 CPU tab 可见时每 2 s（温度和功耗同一批读取），后台历史每 10 s。
- 自检：
  - 结构判据：result 字节正确、档案中的键都存在、取值在 `validRange` 内。
  - 实测判据：档案里的别名与聚合关系仍成立；被动学习与档案不冲突。
  - 按簇逐项判定：一个簇失败只隐藏这个簇（D24）。

### 5.6 CPUMiscCollector（`cpu.misc`）
- `getloadavg()`；`processor_set_statistics(PROCESSOR_SET_LOAD_INFO)` 取任务数和线程数，**不用**其中的 load_average（D29）；`PROCESSOR_CPU_STAT64` 的 IPI、定时器、其余中断差分。
- `ProcessInfo.thermalState` 和 notify `com.apple.system.thermalpressurelevel`：按通知更新，采样时只读缓存值。
- 负载均值在 UI 上注明「约 5 s 更新一次」，因为内核每 5 s 才更新。
- **InterruptDeviceCollector**（`cpu.irq.devices`）：只在面板展开「中断来源」时登记需求，每 5 s 一次；只认通道名「First Level Interrupt Handler Count」，设备名取子组名；输出 Top N 设备（诊断读数，不入历史）。

### 5.7 AppSampler（`app.coalition`，`.blocking` 通道，边界稿 §7.4）
- 全量扫描 `proc_listcoalitions` + `coalition_info_resource_usage`：CPU 时间用槽 24–30 之和，能耗用 slot 11，perflevel0 时间用 slot 22。
- 每个 tick 按 coalition 累加增量。coalition 消失时保留最后一次增量，不补推。
- 两类消费者：
  - Top N（面板 CPU tab 可见时，2 s）；
  - 历史的每应用分钟数据（面板关闭时 background 层每 10 s，D30）。
- **TopNBuilder**：
  - 行名规则、宿主 coalition 副标题、展开时同 uid 成员用 libproc 精确拆分、外部成员归入残差（只在 slot 0/1 不变时才算），都按边界稿 §5.3。
  - 名称和图标按 `p_uniqueid` 缓存；代表成员只对新出现的 cid 算一次。
  - 鼠标悬停在列表上时冻结排序。
- **ProcessKiller**（D31）：
  - GUI app 用 `NSRunningApplication.terminate()` / `forceTerminate()`，其他进程用 SIGTERM / SIGKILL。
  - 只允许同 uid 进程；root、其他用户、组行、SysInfo 自身不提供按钮。
  - 结束前在 MainActor 上弹确认；按住 ⌥ 时默认选「强制」。
- **PSFallback**（D31）：coalition 自检失败时，Top N 只列同 uid 进程（`proc_pid_rusage` v6），并提供「刷新全部」按钮：间隔 2 s 运行两次 setuid `/bin/ps -axo pid=,time=`，取 TIME 差分。**只在点击时运行**，不定时 spawn（CLAUDE.md）。
- 自检：S1–S5（边界稿 §7.5），按槽位分级回退：CPU 槽失败 → 用同 uid 回退；能耗、ptime 槽失败 → 只隐藏对应列。

### 5.8 采集器清单与默认需求

| 采集器 | 通道 | 菜单栏（默认） | 面板 CPU tab 可见 | 后台历史（background 层） |
|---|---|---|---|---|
| `cpu.load` | inline | 1 s | 1 s | 复用菜单栏的 1 s 样本，否则每 60 s 首尾差分 |
| `cpu.freq` | inline | 不采（可选加入，D19） | 5 s | 60 s |
| `cpu.sensors` | blocking | 不采 | 2 s | 10 s |
| `cpu.misc` | inline | 不采 | 1 s | 60 s |
| `cpu.irq.devices` | inline | — | 展开时 5 s | — |
| `app.coalition` | blocking | — | 2 s（Top N） | 10 s（每应用分钟数据） |
| `app.self` | inline | — | — | 诊断页可见时 1 s（M0） |

- 面板内各项间隔可以在设置里改为 1/2/5 s（边界稿 §5.4），由 app 层换算成需求。
- 后台历史登记为 `.background` 层：锁屏、显示器睡眠时继续采，不受降频影响（D30）。

## 6. 历史库（SysStore，D30）

- 引擎：系统 libsqlite3（`import SQLite3`，Apple SDK 自带，不算第三方依赖，D23）。WAL、`synchronous=NORMAL`、`auto_vacuum=INCREMENTAL`；`user_version` 做迁移。
- 位置：`~/Library/Application Support/<bundle id>/History.sqlite`（Debug 与 Release 天然隔离，D16）。`--factory-defaults` 启动时改用临时目录，测量不污染日用数据。
- 表结构按边界稿 §5.5：`metric`、`epoch`、`sample_minute`、`sample_hour`、`app`、`app_minute`。
  - 主键时间在前：`(t, metric)`、`(t, app)`，`WITHOUT ROWID`。
  - 与芯片相关的信息只记在 `epoch` 表里（拓扑 JSON、机型、芯片、系统 build），变化时新开一段。
- **MinuteAggregator**（在 MainActor 外的 actor 上运行）：
  - 订阅引擎事件，按 UTC 分钟聚合 avg、max、n（覆盖秒数）、q（最差质量）。
  - 每 5 分钟提交一个事务；睡眠、退出、导出前立即提交。
  - 只有菜单栏 1 s 采样时才有峰值；后台 60 s 差分得到的指标，max 记为空，不假装有峰值。
  - 每应用：每分钟取 CPU 用量前 10 的应用写进 `app_minute`。
- 整点过后 1 分钟做小时汇总，按 n 加权。每天清理一次过期数据（DELETE + incremental_vacuum）。
- 空洞处理：睡眠期间不写行；唤醒后的第一个差分丢弃；计数器回退按复位处理；墙钟回拨造成主键冲突时，用 UPSERT 按 n 加权合并。
- 保留期：分钟级 30 天（含每应用），小时级永久且只存整机指标。设置里可以「一键清除每应用数据」（D30）。
- **Exporter**：手动触发，可选时间范围、粒度、指标组和格式。
  - CSV 导出为一个文件夹：`system.csv`（宽表）、`apps.csv`（长表）、`metadata.json`。
  - JSON Lines 是长表，首行写元数据。
  - 不导出任何设备唯一标识（CLAUDE.md、D30）。
- 面板读历史：1 时读分钟表；24 时读分钟表并降采样到约 300 点；7 天读小时表。画成均值线加峰值带，空洞处断开。

## 7. App 层

### 7.1 菜单栏 item（D32）
- `CPUStatusItemView` 改为按样式绘制：`.stacked`（默认）、`.inline`（M0 的「CPU 23%」）、`.sparkline`、`.bars`（总量 / 按档 / 每核）。
- **上下布局**：
  - 上行是标签「CPU」，下行是数值，数值用 `monospacedDigitSystemFont`，两行都水平居中。
  - 初始字号：标签 8 pt medium，数值 12 pt。宽度按「100%」在 12 pt 下的字宽加左右各 2 pt 算出，估计 32–36 pt，运行中不变。
  - 具体字号在两台机器上截图自查后定，结果写进偏离记录。
- 着色（D32）：
  - 对总占用做 EMA（τ = 1.5 s，M0 已有）。持续 10 s ≥85% 变 systemOrange，≥95% 变 systemRed，回落时留 5 个百分点滞回。
  - 阈值放在共享配置 `ColorThresholds` 里，P2 的提醒直接复用。
  - 平时用 `labelColor`，温度和热状态不参与着色。
- 设置页的预览直接用真实的 item view 渲染。
- 迷你折线读 `MetricStore` 的环形缓冲；柱状的每核柱宽 = 核数 × 约 3 pt，启动时按拓扑算一次，运行中不变。

### 7.2 面板 CPU tab（边界稿 §5.2）
- 分区：
  - **概览**：大号总占用和用户/系统细分条。右侧三个小值：最快档的实际频率、CPU 最高温、热状态徽标。
  - **历史图**：跨度 2 分、15 分读环形缓冲；1 时、24 时、7 天读历史库。默认 2 分。
  - **核心**：
    - 按档分组，快档在前（按 perflevel 序号）。组标题形如「性能核 ×10 · 45% · 62 °C」。
    - 每簇一行：占用、实际频率、簇温度、簇功耗；每核柱按档着色。
    - 没有温度行的簇（E 簇、档案里没有的簇）这一格留空，不显示「不可用」字样；原因在诊断页说明。
  - **详情**（默认折叠）：负载均值、开机时间、任务与线程数、中断三项；「中断来源」再展开一层。
  - **Top N**：默认 5 行，可选 0/3/5/8/10。
- 档名本地化：Super → 超级核，Performance → 性能核，Efficiency → 能效核；不认识的名字原样显示。颜色按名字取，不认识的按序号取备用色。
- 温度旁加说明「簇所在位置的温度，GPU 重载时也会升高」。功耗旁注明「不含 GPU」。
- 需求只在 CPU tab 可见时登记（D29），切到别的 tab 或面板关闭就注销。
- 内存环形缓冲的保留期仍为 15 分钟（K39）。

### 7.3 设置页
> 2026-10-15 按 D41 重排：widget 开关与配置、阈值、历史记录开关都并入 CPU 页；「占用的样式」拆成全局排版（菜单栏页）与占用的呈现形式（CPU 页）；历史页只保留历史库、清除、导出与记录状态总览。下面是 D41 之前的原稿。

- **CPU 页**：
  - 采集：模块间隔覆盖（M0 已有）；面板内频率、温度与功耗、Top N 的间隔（1/2/5 s）。
  - 菜单栏：样式、「CPU」标签开关、着色开关与阈值、实时预览。
  - 面板：图表默认跨度、是否拆分用户/系统、Top N 行数、分组方式（按应用 / 按进程）。
  - 高开销选项：每项标注「约 +x% 单核」。数值取诊断页里本机实测的滑动平均；还没有实测值时，显示参考值并注明「参考 M5 Pro / M4 Pro」。包括：
    - 菜单栏显示频率（1 s 约 +0.9%，5 s 约 +0.18%）；
    - 面板 1 s 刷新；
    - 后台高精度历史（频率、温度每 5 s）。
- **历史与导出页**：是否记录 CPU 历史、是否记录每应用 CPU、清除每应用数据、导出。
- **隐私页**（D27）：「数据存放」一项加上历史库路径和本机校准缓存路径。
- 设置键名延续 M0 的风格：`cpu.panel.freqInterval`、`cpu.panel.sensorInterval`、`cpu.panel.topNInterval`、`cpu.panel.topNRows`、`cpu.panel.grouping`、`menubar.cpu.style`、`menubar.cpu.label`、`menubar.cpu.coloring`、`history.cpu.enabled`、`history.apps.enabled`。

### 7.4 诊断页（K19）
- 每个数据源的状态和当前走的路径：
  - 频率：实际还是请求；
  - 温度：来自档案、学习中、已校准还是冲突；
  - 功耗：专用轨还是不可用；
  - Top N：coalition 还是同 uid 回退。
- 拓扑：三种档次依据各自的结果，以及是否一致。
- 芯片档案：socID、来源、已验证的 build，以及当前 build 是否已验证。
- 诊断读数（只在这里显示）：请求频率、逐核频率、每个温度键的原始值（标出占位值）、E 簇附近读数、x2 峰值、阻塞通道的 `skippedBusy` 次数。
- 「传感器校准」按钮（§5.5）。

## 8. 命令行（sysinfo-cli）

| 子命令 | 用途 |
|---|---|
| `topo [--json]` | 打印拓扑、三种档次依据和一致性 |
| `freq [--interval 5] [--count N] [--json]` | 每簇实际频率和请求频率 |
| `sensors [--json] [--raw]` | 簇温度、簇功耗；`--raw` 打出所有键的原始值并标出占位值 |
| `topn [--interval 2] [--rows 10] [--json]` | Top N（按应用 / 按进程） |
| `verify freq` | 分段负载（≤60 s），按档对照实际通道与内核 `PROC_PIDTHREADCOUNTS`，从 `sk_verify.c` 移植 |
| `verify topn` | Top N 与 setuid `ps` 的 TIME 差分对照，kernel_task 另用 `top -l 2 -s N -pid 0` |
| `calibrate [--emit-profile out.json]` | 运行传感器校准（≤60 s 负载），可以输出档案 JSON |
| `history stats` / `history export …` | 历史库的统计与导出（对 `.dev` 数据目录） |
| `selftest`、`cpu`、`engine` | M0 已有；`selftest` 加入新数据源 |

- 带负载的子命令（`verify freq`、`calibrate`）启动前打印时长和负载说明，需要 `--yes` 才执行。Claude 在对照机上运行它们之前，先告诉用户（D18）。
- `remote-cli` 照旧：远端只写 `/tmp/sysinfo-remote`。

## 9. 测试（K25，Swift Testing）

- 纯函数单测：
  - 拓扑：三种档次依据，以及冲突、核数不等、多 die、三档的合成输入；
  - 频率：通道结构识别（用 M5、M2、M4 的通道名列表作金样本）、DVFS 表的单位与合法性、驻留加权平均、空闲判定；
  - 温度：占位值过滤、别名合并、聚合检测、非负最小二乘归簇（用 `m4out/*.csv` 等记录的脱敏片段作金样本）；
  - 功耗：轨归属、GPU 独立性检查；
  - coalition：残差计算、截断重试、slot 校验；
  - 历史：分钟聚合、小时汇总、空洞与回拨、保留期清理、导出格式。
- 金样本只放脱敏后的数值和键名，不放序列号、UUID、MAC、IP（K25、`.gitignore`）。
- 硬件测试（`.hardware` 标签，`make test-hw`、`make remote-test`）：
  - 拓扑与本机的 `hw.*` 一致；
  - IOReport 订阅可建、驻留增量 / 墙钟落在 timebase 频率的 0.97–1.02 倍；
  - SMC 枚举可读、档案中的键都存在；
  - coalition 自检 S1–S5 通过。

## 10. Makefile、度量与日志

- `make measure` 扩展为四档：
  - 基线；
  - 出厂默认（1 个 CPU item，面板关闭，历史开启）；
  - CPU 面板打开（`--open-panel`，CPU tab 可见）；
  - 面板打开且 Top N 展开。

  结果写入 `docs/perf/cpu.md`。新增 `make remote-measure`：在对照机上做同样测量，远端检测到 Stats 时同样拒绝执行。
- 开销口径照旧：以 `ps -o time=` 的差值为准。另用 coalition 的 CPU 槽做旁证，私有层建好后两者应一致（M0 设计 §9 的遗留项）。
- 日志 category：`topology`、`ioreport`、`smc`、`sensors`、`coalition`、`history`。热路径只打 debug 级别的日志，并且限速；机器标识一律用 `.private`（K29）。

## 11. 实施顺序（分支内小步提交，D17）

1. 私有 C 层与封装：IOReportHub、SMCReader、CoalitionReader，加上硬件测试。
2. 拓扑发现与 `cpu.load` 扩展；CLI `topo`。
3. 频率采集器与自检；CLI `freq`、`verify freq`。
4. 引擎的阻塞通道；SensorCollector；芯片档案（M5、M4）与占位值；CLI `sensors`、`calibrate`。
5. AppSampler、Top N、ProcessKiller、PSFallback；CLI `topn`、`verify topn`。
6. SysStore 历史库、后台需求、导出；CLI `history`。
7. App：菜单栏上下布局、面板 CPU tab、设置页、诊断页、隐私页补充。
8. `make measure` 两台实测、截图自查、验收报告。之后交给用户验收（D14），合并 `main` 前需要用户确认（D17）。

每一步结束时在两台机器上跑一遍对应的 CLI 子命令，并把对照结果记进偏离记录或验收报告。

## 12. 偏离记录

（实现过程中偏离本文的地方记在这里：日期、内容、原因。）

- **2026-10-15 · §3 私有符号改为运行时 dlsym 解析，不做链接期弱链接**
  - 原文写的是「`__attribute__((weak_import))` 弱链接」（沿用 D23 / K12 的说法）。实现中，IOReport 用 `dlopen("/usr/lib/libIOReport.dylib")` + `dlsym`，coalition 用 `dlsym(RTLD_DEFAULT, …)`，都在第一次使用时用 `pthread_once` 解析一次。
  - 原因：弱链接仍然要在链接期依赖 `libIOReport`（SwiftPM 需要 `-weak-lIOReport` 这类 unsafeFlags，Xcode 和 `swift build` 两边都得配）；dlsym 不需要任何链接设置，符号缺失时同样只让对应的 `csp_*_available()` 返回 0，效果与 D23 的意图一致：app 照常启动，上层回退或显示不可用。
  - 对上只暴露 `csp_*` 封装函数，私有符号本身不出现在头文件里。SMC 的读写共用 selector 2，所以「不写 SMC」靠命令白名单保证：私有层只定义三个读命令，`smc_call` 在调用前检查命令字节，单测遍历 0–255 核对只有 5、8、9 被放行。
  - coalition 的「写出字节数」探测（自检 S3）拆成单独的 `csp_coal_resource_usage_probe`，常规采样只调用一次 `csp_coal_resource_usage`。
- **2026-10-15 · §9 硬件测试：`*_IDLE` 通道不是完整的时间积分**
  - M4 Pro 实测 `PCPM_IDLE`（状态里是 `NON_IDLE` 而不是 `IDLE`）的驻留增量 / 墙钟只有 0.48，而标准性能状态通道是 1.00。驻留积分的硬件测试只检查带 `IDLE` 状态的通道；频率发现按 §5.4 的结构规则本来就排除这类通道。
- **2026-10-15 · §5.4 IOReportHub 的线程安全：通道访问器会写字典**
  - 实测：并行跑硬件测试时稳定崩溃（SIGSEGV）。栈为 `IOReportChannelGetChannelName` → `-[__NSDictionaryM __setObject:forKey:]`：访问器会把结果缓存进通道字典，所以「只读」访问也不能并发。拓扑发现（自检线程）和频率采样（引擎队列）在生产环境里同样可能并发读到同一份缓存字典。
  - 做法：
    - 缓存的组字典只在 hub 的锁内访问，通道信息在枚举时算一次，缓存成值类型；
    - 建订阅时在锁内用 `CFPropertyListCreateDeepCopy` 深拷贝组字典，筛选、合并和订阅只用这份拷贝，每个订阅独占自己的 CF 对象。
  - 回归测试：16 个线程同时读通道、建订阅、采样（`concurrentChannelAccessAndSubscriptions`）。修复后本机并行连跑 5 次、M4 跑 1 次，均通过。
- **2026-10-15 · §5.2 拓扑：频率依据与被动核对的接入时机**
  - 频率依据（DVFS 表顶）要用到第 3 步的通道与 pmgr 表发现。现在 `TopologyInputs.tableTopByCluster` 先留空，`topo` 显示「no DVFS tables」；第 3 步接入后由频率发现传入，三种依据一起核对。
  - 用 rusage v6 `ri_*_ptime` 做被动核对需要知道本进程线程在哪个簇上运行，常规采样里拿不到。改为在第 5 步用系统级数据核对：全体 coalition 的 perflevel0 时间（slot 22）之和 / CPU 时间之和，应约等于按映射算出的 perflevel0 核忙碌 tick 占比。
  - 两台实测（`topo`）：
    - M5 Pro：3 簇（d0c0、d0c1 为 Performance，d0c2 为 Super）；
    - M4 Pro：3 簇（d0c0 为 Efficiency，d0c1、d0c2 为 Performance）。
    - 两台都是核数与 L2 两种依据成立且一致，状态 ok。
- **2026-10-15 · §5.4 IOReport 枚举结果里没有状态名**
  - 实测：`IOReportCopyChannelsInGroup` 返回的通道字典里，`IOReportStateGetCount` 为 0，状态名要从一次样本里取（探针当初也是从样本里读的）。
  - 做法：`IOReportHub.stateNames(inGroup:where:)` 建一个临时订阅、采一次快照（`IOReportSubscription.snapshot()`），只在建采样方案时调用一次。`IOReportChannelInfo.stateNames` 的文档已注明枚举结果里它为空。
- **2026-10-15 · §5.4 频率采集器的落地细节与两台实测**
  - 订阅只包含方案里用到的簇通道（实际 + 请求），不订阅逐核通道；逐核频率留给诊断页按需订阅（第 7 步）。
  - 活跃驻留占比低于 0.2% 判为空闲，输出 `unavailable(clusterIdle)`。
  - 拓扑的 generation 变了而采样方案还没重建时，频率输出不可用；引擎连续收到不可用后会触发复检。
  - 主动核对：自旋 50 ms，线程 ≥90% 的时间停在同一簇才下结论，最多试 3 次；3 次都跨簇时记为「不确定」，不算失败。
  - 被动判据推迟到第 5 步，届时用 coalition 全量求和的按档 cycles 核对，并做「每核 tick 忙碌与逐核通道活跃的相关系数 ≥0.99」检查。
  - 拓扑的频率依据已接入：两台的 `topo` 现在三种依据都成立且一致。
  - `sysinfo-cli verify freq`（每段 3 s，共约 14 s 负载，Stats 均未运行）：
    - M5 Pro：各档实际通道误差 ≤0.4%；请求通道在 Super 多核时 +8.78%。
    - M4 Pro：各档实际通道误差 ≤0.02%；请求通道在 P 簇多核时 +17.13%。
    - 结论与边界稿 §2.2、§9.1 一致。
  - 真实节奏开销（`freq --interval 5`，每次采样的线程 CPU 时间）：M5 8.2–8.7 ms，M4 8.6–8.8 ms，5 s 一次约 0.17% 单核。
- **2026-10-15 · §5.1 阻塞通道的落地**
  - 协议加 `lane`（默认 `.inline`）；`.blocking` 的采集器在第二条串行队列上执行，完成后回到引擎队列更新健康信息、单独交付一个 `TickResult(lane: .blocking)`。
  - 上一次还没结束就跳过本 tick，计入 `CollectorHealth.skippedBusyCount`。
  - 主 tick 里没有内联采集器时不交付主结果。`MetricStore` 只用主结果的耗时作「tick 耗时」。
  - 引擎的自检顺序改为登记顺序：`cpu.load` 的自检刷新拓扑，必须排在按拓扑建方案的 `cpu.freq`、`cpu.sensors` 前面。原来按 ID 字母序，`cpu.freq` 会先拿到旧拓扑。
- **2026-10-15 · §4.3、§5.5 芯片档案与 SensorCollector 的落地**
  - SoC 标识是 pmgr 节点下 PMGR 驱动的类名（M5 Pro 为 AppleT6050PMGR，M4 Pro 为 AppleT6041PMGR）。pmgr 节点本身的类名是 AppleARMIODevice，不能用。
  - 档案 JSON 的字典以字符串为键（簇键写成 `d0c1`），去掉了原文的 `frequency` 段：频率方案运行时发现，不需要档案核对。
  - 只内置 M5 Pro 与 M4 Pro 两份档案。M2 Max 不再是目标设备（D28），没有做档案。
  - key-info 不按 build 持久化：常规采样只读档案里的约 60 个键，自检时现取 key-info 约 12 ms，不值得多一层缓存。
  - 有效温度范围由 5–130 °C 改为 10–125 °C：M4 刚上电时会读到 1–5 °C 的瞬态值。
  - 未知芯片（没有档案）：温度为「学习中」，功耗为「无专用轨」。被动学习与对已知芯片的被动核对（GPU 负载时簇轨不涨、别名关系仍成立）推迟到第 5 步之后单独做：它们要用到跨采集器的数据（GPU 功率、各簇占用）。
- **2026-10-15 · §5.5 M4 Pro 的两个 P 簇分不出温度归属（更正边界稿 §9.3）**
  - 校准时发现：两个 P 簇的温度键在任一 P 簇有负载时都同时上电。在新旧两份录制里，调研归为 P0 的 Tp01 和归为 P1 的 Tp09，对「P0 − P1」方波的滞后相关曲线几乎完全相同（滞后 0–1 时 +0.5，滞后 4–5 时 −0.87）。
  - 调研 §9.3 是对每个键取「绝对值最大的相关」，混用了不同的滞后，把同一类键分成了正、负两组，这是假象。功耗轨则分得很清楚（RP05 +0.87，RP00 −0.87），§9.2 的功耗结论不变。
  - 内置 M4 档案已改为两个 P 簇共用同一组 14 个代表键（原两组之并）。这样两个 P 簇的温度永远相同，UI 怎么显示请见下一条待确认项。
- **2026-10-15 · §5.5 传感器校准的方法与验收口径**
  - 方法由「高通回归」改为「阶跃证据」：相邻两段尾部 3 s 均值之差，ΔT ≈ 常数 + Σ 组敏感度 × Δ功率（有专用轨时按瓦，否则按占用）。
    - 常数项吸收持续升温的漂移；
    - 同一档里从没被单独加载过的簇（M4 的两个 P 簇来回切换）合成一组，键归到整组；
    - 判归属看满载贡献（敏感度 × 该组最大功率），领先 1.5 倍；离哪个簇最近看每瓦敏感度，只用于「附近」读数。
  - GPU 判据：
    - CPU 空闲时断电、GPU 段才有读数的键是 GPU 供电域，排除（M4 的 Tp1*、Tp2*：空闲有效 3%，GPU 段 92%）；
    - GPU 段温升超过满载贡献的，排除；
    - 其余只在 GPU 比值超过同组中位数的 2 倍时排除。GPU 段会让整片芯片一起升温，短负载下绝对比值不稳。
  - 另有三条规则：
    - 聚合键：逐行等于不同的其他键（M4 的 Tpx*），排除；
    - 热点离群：比本组中位数高出 Q3 + 3×IQR（M5 的 TVDC/TVDP，+13 °C），排除；
    - 功耗轨去重：量级相近且高度相关的是同一路电的重复测量（PP*b 与 RP*），只留一个；量级差超过 15% 时留最小的（M4 的 PPMR ≈ 1.3 × RP00）。
  - 段顺序：GPU 段放在 CPU 负载之前。放在之后会赶上整体降温，GPU 段的升温被抵消。
  - 验收口径：内置档案里的温度键必须全部找回（召回 100%）、归属正确；内置的功耗轨必须找回（重复测量视为等价）。多出的键只列为候选，需要人工确认。
  - 实测：M5 两次、M4 一次（每次约 58 s，CPU 负载 30 s、GPU 负载 12 s，Stats 均未运行），三次都召回完整。
  - 多出来的候选主要是 die/SoC 传感器（TPD*、TVD*、Tf*、Ts0C 等）。它们会让簇最高温偏高：第一份 M5 录制里 Super 平均 +7 °C；M4 的 TPD* 在 P 核断电时仍有读数，簇温度会显示 die 温度而不是「—」。所以校准结果目前只适合没有内置档案的芯片，见下一条待确认项。
- **已定（2026-10-15，D37）**：
  - ① 有内置档案的芯片，校准只出核对报告，不覆盖内置档案；没有内置档案的芯片才启用校准结果（`ChipProfileStore.resolve` 已改为内置优先）。
  - ② 几个簇共用同一组温度键时，温度只显示在档的组标题里，簇行留空（第 7 步实现）。
- **2026-10-15 · §5.7 AppSampler 与 Top N 的落地**
  - AppSampler 只扫描有成员的 coalition（`tasks > 0`）。常驻的空 launchd job 没有 CPU 增量，不读。
  - 新出现的 coalition 取当前累计值作增量：它的全部用量都发生在窗口内。
  - AppSampler 本身只输出整机汇总样本：全体进程 CPU、perflevel0 时间占比、两档的内核平均频率，供被动核对使用。每个 coalition 的增量留在 `latestWindow` 里。Top N 由 `TopNBuilder` 在消费者需要时（面板可见）另外组装。
  - 自检 S5（自旋比对）只在本进程独占自己的 coalition 时判定：CLI 在终端里运行时，coalition 里还有别的进程，记为跳过。
  - 行名不用 AppKit：
    - 有 .app 时取最外层 .app 的 CFBundleDisplayName / CFBundleName；
    - 否则取可执行文件名；pid 0 显示 kernel_task；
    - 图标与 `NSRunningApplication` 的激活策略留给 app 层（第 7 步）。
  - 「结束」用信号（SIGTERM / SIGKILL），GUI app 的优雅退出由 app 层用 `NSRunningApplication` 处理。资格判断在发信号前完成：root、其他用户、pid ≤1、本进程一律拒绝。
  - 开销（`topn`，第二轮起）：扫描加组装每次 M5 约 10.8 ms、M4 约 14 ms，2 s 一次约 0.5–0.7% 单核，高于边界稿的 0.33–0.39% 估算。多出来的主要是成员的 rusage 与名称查询，第 8 步测开销时优化。
- **2026-10-15 · §5.2、§5.4 被动核对的落地（第 2、3 步推迟到这里）**
  - `PassiveValidator` 吃引擎的 tick 结果。三个采集器的间隔不同，所以在「三者同一 tick 都有样本」的公共边界之间，各自累加自己的窗口再比较。
  - 频率按各频率窗口内本簇的忙碌核·秒加权：只按时长平均时，M5 的 perflevel1 实测偏 −12.8%，因为簇大半时间空闲的窗口占满了权重。
  - 两台实测（`verify passive --yes`：前 15 s 为 perflevel0 核数个 UI 线程，后 15 s 为全核 utility 线程，Stats 均未运行）：
    - M5：拓扑占比 74.1% 对 74.0%、35.3% 对 35.3%；频率 perflevel0 +0.0%，perflevel1 −1.7%；
    - M4：拓扑 90.4% 对 90.4%、71.5% 对 71.5%；频率两档都是 ±0.0%。
  - 「每核 tick 忙碌与逐核通道活跃的相关」这一项需要订阅逐核通道，留到第 7 步与诊断页的逐核频率一起做。
  - 被动核对的结果目前只在 CLI 输出。接进诊断页，以及失败时触发复检，在第 7 步做。
- **2026-10-15 · §8 `verify topn` 的对照口径**
  - 两次 `ps` 各要跑几十毫秒，TIME 的取样时刻按运行区间的中点算，AppSampler 的两次扫描紧挨着两次 `ps`。原先按起止时刻算，稳定在 134% 的进程会差 1.9 pp。
  - 不含 kernel_task 所在的 coalition（pid 0 不在 `ps` 里），也不含本命令所在的 coalition（`ps` 子进程会算进去）。
  - 两台实测（5 s 窗口）：前 10 名最大差 M5 0.39 pp、M4 0.06 pp。
- **2026-10-15 · §5.5 补充：刚上电的瞬态读数**
  - M4 的 P 核键刚上电时会读出 1–5 °C。这类低于有效下限的读数和占位值一样按「此刻没有读数」处理：簇温度显示「—」，自检不判为异常。原先自检会把它判成不合理，M4 的硬件测试因此偶发失败。
- **2026-10-15 · §5.6 `cpu.misc` 在第 6 步补上**
  - §11 的实施顺序漏了这个采集器，历史库要用负载均值和热状态，所以在第 6 步一起实现，登记在 `StandardCollectors` 里（排在 `cpu.freq` 之后）。
  - 指标：`cpu.loadavg.1/5/15`、`cpu.tasks`、`cpu.threads`、`cpu.irq.ipi/timer/other`（每秒，全部核之和）、`cpu.thermal.state`（`ProcessInfo.thermalState` 原始值）、`cpu.thermal.pressure`（notify 热压力等级）。
  - 中断「其余」= irq − IPI − 定时器；余量为负或任一计数回退时按复位处理，丢弃这一段。
  - 热压力用 `notify_register_check` + `notify_get_state` 读共享内存，不经 IPC，采样时直接读，不另做通知回调。
  - 两台 `selftest` 均通过（M5：tasks≈980、threads≈4400）。
- **2026-10-15 · §6 SysStore 的落地**
  - 新 target `SysStore`（依赖 SysModel、SysCollectors，不依赖私有层），已加进 `check-private-imports` 的检查范围；app 链接它。
  - 入库指标由 `HistoryCatalog` 按前缀判定：总占用、用户/系统、每档占用、每簇频率、每簇温度、CPU 最高温、每簇与总功耗、1 分钟负载均值、热状态、热压力。比边界稿 §5.5 多了功耗（C1 改定为 B 之后）和热压力。
  - 两类聚合：
    - 区间量（占用、频率）按墙钟拆到所跨的分钟，按重叠秒数加权；
    - 瞬时量（温度、功耗、负载均值、热状态）整份记到所在分钟，覆盖秒数取距上次采样的间隔，上限 60 s。
  - 样本覆盖的区间 = 距同一采集器上一次运行的单调时钟差（采集器建立基线的那次也算一次运行）。唤醒后清空，丢弃第一个样本。
  - 峰值规则落成：区间量只有区间 ≤10 s 的样本才有峰值，这一分钟混进更长的样本，max 记为空。菜单栏 1 s、面板 5 s 有峰值，后台 60 s 没有。小时汇总同理：每行都有峰值时才给。
  - 提交：每 5 分钟一次，在分钟号 ≡ 0 (mod 5) 的整分之后 62 s（:01、:06…），只写已结束的分钟。`flush()`（睡眠、退出、导出、面板读历史前）连当前分钟一起写；之后到达的数据按 UPSERT 合并，n 加权。
  - 退出时 `applicationWillTerminate` 同步等记录器 `stop()`，最多 2 s。
  - `--factory-defaults` 时历史库放在临时目录 `SysInfo-factory-<pid>`。
  - 每应用：
    - 应用身份键取代表成员所在最外层 .app 的 bundle id，没有 .app 时取可执行文件路径，pid 0 为 `kernel_task`；代表成员的选法与 Top N 一致。
    - coalition 退出后就解析不到，所以每个窗口到达时就为前 16 个 coalition 解析身份，按 coalition id 缓存。
    - Top N 只读 `latestWindow`，面板和历史共用扫描时会漏掉中间窗口，所以 AppSampler 增加了窗口留存（`setRetainsWindows` / `drainRetainedWindows`，上限 64 个），只在记录每应用数据时打开。
    - 某一分钟里任一窗口的能耗槽不可信时，该分钟能耗记为空。
  - 设置键 `history.cpu.enabled`、`history.apps.enabled`（默认开）已加进 `AppSettings`，界面留到第 7 步。
  - CLI：`history stats`、`history export`（默认读 `.dev` 数据目录）、`history record --db …`（必须显式给路径，对照机只写 `/tmp/sysinfo-remote`）。
- **2026-10-15 · §5.7 修正：重新有成员的旧 coalition 被当成新的**
  - 现象：第一次 `history record`（本机 200 s）里 `biomesyncd` 记了 810 CPU·s，远超可能值。
  - 原因：AppSampler 不扫描成员为 0 的 coalition。launchd 周期拉起的服务，每次有了成员，就被当成「新出现」，把开机以来的累计用量整份算进窗口。Top N 也会因此偶尔冒出假尖峰。
  - 做法：coalition id 单调递增。只有 id 大于上次扫描见过的最大 id（含成员为 0 的）才算真正新出现；不大于、上次却没扫描到的，这一轮只建基线。单测 `CoalitionDeltaTests` 覆盖。
- **2026-10-15 · §6 两台实测（`history record --seconds 200 --menubar`，修正后，Stats 均未运行）**
  - M5 Pro：
    - 写入分钟行 73、每应用行 40，指标 19 个；
    - 本进程 0.171% 单核（含 CLI 自身与 1 s 菜单栏需求）；
    - 每应用合计 353 CPU·s，整机按 `cpu.usage.total` 积分 372 CPU·s。
  - M4 Pro：
    - 分钟行 49、每应用行 40，指标 13 个；
    - 0.254% 单核；
    - 每应用合计 30.6 CPU·s，整机 35.6 CPU·s。
    - 空闲时 P 核断电，`cpu.temp.max` 没有行（D33 的「—」）。
  - 每分钟只留前 10 个应用，合计略低于整机，符合预期。修正前，本机的应用合计远超整机（`biomesyncd` 一项就 810 CPU·s）。
  - 导出：CSV 文件夹与 JSON Lines 都核对过，不含设备唯一标识。
  - 正式的开销测量按 §10 在第 8 步用 `make measure` 做。这里的数字含 CLI 与 Swift 运行时，只作参考。
- **2026-10-15 · §7.1 菜单栏上下布局的字号**
  - 原文初始字号是标签 8 pt、数值 12 pt。截图自查后，用户要求上下两行字号一致，改为两行都用 10 pt medium（数值用等宽数字）。宽度按「100%」在 10 pt 下的字宽加左右各 2 pt 算出，约 29 pt。
  - 垂直方向按「数值大写高度 + 2.5 pt + 标签大写高度」整组居中。原先按行高摆放时两行会重叠。
  - 迷你折线、柱状样式沿用同一套布局：上行是标签，下行的数值区换成图形；关闭标签后，图形占满整个高度。
  - 着色状态机 `SustainedLevelTracker` 与阈值 `ColorThresholds` 放在 SysModel（P2 的提醒复用），有单测。
- **2026-10-15 · §7 App 层的落地（第 7 步进行中）**
  - 面板：
    - 宽度由 340 改为 360 pt，簇行的五列（簇、占用、频率、温度、功耗）放得下；
    - 内容高度变化时（展开详情、Top N 行数）面板跟着改高，保持顶边不动；
    - Top N 的组装在后台执行，不占 MainActor。
  - 诊断页：
    - CPU 部分（数据源路径、拓扑与档案、被动核对、校准、诊断读数）放在最前，采集器明细移到后面；
    - 截图自查改用辅助功能接口设置滚动条：SwiftUI Form 不响应合成滚轮事件。
  - 校准比对逻辑从 CLI 移进 SysCollectors（`CalibrationComparison`），CLI 与诊断页共用，CLI 输出不变。
  - Debug 启动参数新增 `--open-settings=<页面>`（`cpu`、`history`、`diagnostics` 等），用于截图自查。
- **2026-10-15 · §5.6 中断来源 `cpu.irq.devices` 的落地**
  - 通道名前面补了空格（`               First Level Interrupt Handler Count`），比较前去掉首尾空白。
  - 子组名带中断序号（`i2c5 0`），合并同一设备时去掉末尾的序号。
  - 两台实测（`irq`）：
    - M5：384 个通道、158 个设备；空闲时约 1.2k/s，gfx-asc 最多；
    - M4：227 个通道、119 个设备；空闲时约 20/s。
  - 真实节奏下单次采样的线程 CPU：M5 约 12.5 ms，M4 约 13.5 ms。5 s 一次约 0.25–0.27% 单核，只在展开「中断来源」时运行。比边界稿的紧循环值（3–6 ms）高，原因与 D34 相同。
- **2026-10-15 · §5.4 逐核频率与相关性核对（第 3 步推迟到这里）**
  - 新采集器 `cpu.freq.cores`：只在诊断页可见时每 2 s 一次，复用 `cpu.freq` 的方案，订阅全部逐核通道；同一窗口里再读一次每核 tick。
  - 判据：「每核 tick 忙碌比例」与「逐核通道活跃驻留比例」的相关系数 ≥0.99。点数少于 4、或任一方标准差小于 0.02 时记为「不确定」。
  - 两台实测（`cores`）：M5 0.9998，M4 0.9994 / 0.9988。单次采样约 8.4 ms（M5）/ 9–10 ms（M4）。
- **2026-10-15 · §7.3 高开销选项**
  - 「后台高精度历史」已实现：设置键 `history.cpu.highPrecision`，默认关；打开后，后台的频率、温度与功耗改为每 5 s。
  - 「菜单栏显示频率」的呈现方式待用户定（见验收前的待定项）。
- **2026-10-15 · §7.1 菜单栏改为一项一个 widget（D38）**
  - CPU 模块提供四个 widget：占用（默认开）、频率、温度、功耗（默认关）。每个都是独立的 `NSStatusItem`，各自登记需求：
    - 占用 → `cpu.load`；
    - 频率 → `cpu.freq`；
    - 温度、功耗 → `cpu.sensors`。
  - 小标签用英文缩写：CPU、FREQ、TEMP、PWR（D23）。数值格式为 `23%`、`1.68G`、`47°`、`0.8W`，宽度按 `100%`、`9.99G`、`125°`、`99.9W` 固定。
  - 频率 widget 显示各簇实际频率的最大值（最忙的簇），全部空闲时显示「—」。面板概览里仍显示最快档的频率。
  - 占用 widget 保留全部样式（上下、左右、折线、柱）与着色；其余三个只有上下、左右两种，不着色。
  - 占用 widget 的 autosaveName 沿用 `<bundle id>.cpu`，保住用户拖好的位置；其余为 `<bundle id>.cpu.<项>`。
  - 点击任一 widget 都打开同一个面板，锚在被点击的 widget 下方（`StatusItemController.activeItem`）。
  - 实测：四个 widget 一起显示正常；点击 TEMP 后，面板锚在它下方，Esc 可以关闭，修饰键无残留。
- **2026-10-15 · 两台截图自查（D39）**
  - 新增 `scripts/remote-app.sh` 与 `make remote-app-build / -run / -shot / -clean`：
    - 在 M4 上用 xcodebuild 构建 Debug 版，产物与 DerivedData 都放在 `/tmp/sysinfo-remote`；
    - 远端用 ad-hoc 签名：远端改了 HOME，钥匙串里的 Developer ID 证书用不了，也不该去碰；
    - 启动时总是带 `--factory-defaults`，并把 TMPDIR 指向 `/tmp/sysinfo-remote/tmp`；
    - 截图用 `scripts/window-shot.swift`：取 SysInfo Dev 最大的窗口（面板在 popUpMenu 层级），需要时用辅助功能接口滚动。
  - 清场：
    - 结束 app，按可执行文件路径匹配，`/tmp` 与 `/private/tmp` 两种写法都认；
    - `lsregister -u` 取消登记；
    - 只删除启动前不存在的痕迹：状态栏 item 的位置会写进偏好 plist，`--factory-defaults` 也拦不住。
    - 实测清场后 M4 家目录里没有 `zone.lyl.sysinfo.dev` 的任何文件，LaunchServices 里也没有登记。
  - M4 截图结论：
    - 面板：两个 P 簇共用温度键，温度只显示在「性能核 ×10」的组标题里，簇行留空（D37）；能效核没有温度行（D33）；功耗按簇显示。
    - 诊断页：三种档次依据一致；档案为内置的 M4 Pro。
  - 本机（M5 Pro）：面板、四个菜单栏 widget、设置的 CPU 页、诊断页都截图核对过。
- **2026-10-15 · §10 开销实测与面板优化（第 8 步）**
  - 第一次四档实测（原始 CPU）：面板打开 M5 3.16%、M4 5.09%，超出 D19 的 2%；M4 常驻 0.52%，略超 0.5%。
  - 面板的优化，按效果从大到小：
    - 每秒都在变的概览、核心区和图表绘制区改成 AppKit 自绘（`Panel/LiveViews.swift`），在 `draw(_:)` 里直接读 MetricStore。数据更新时只重绘这几个 view，SwiftUI 不再重算、重排整棵树。footprint 由 121 MB 降到 25 MB。
    - MetricStore 攒批发布：同一个 tick 的主结果和阻塞结果（晚到 10–70 ms）合并成一次观察变化（`revision`）。菜单栏的平滑占用和着色级别不经节流。
    - 面板只在结构变化时量一次高度：展开或收起、Top N 行数或成员变化、第一次采样后核心区成形。原先每次更新都算 `fittingSize`，对整个面板做一次理想尺寸布局。
    - 两个分段控件（模块 tab、图表跨度）换成纯 SwiftUI 的轻量按钮组。系统的分段控件底层是 NSSegmentedControl，每次布局都要重新测量。
    - 图表从 Swift Charts 改为自绘；每核小柱从每核一个 GeometryReader 改为一次画完。
  - 重绘计数：设环境变量 `SYSINFO_DRAW_STATS` 后，每 30 s 写一次日志。两台都是每个自绘 view 每秒重绘 1 次。
  - M4 慢的原因：系统把 SysInfo 约 95% 的 CPU 时间调度到能效核（Top N 的 p0 占比 5%），同样的工作在能效核上的 CPU 时间约是性能核的 2–3 倍。M5 没有能效核。由此定 D40：开销按最快档等效时间考核。
  - 测量脚本：四档（基线、出厂默认、面板打开、面板 + 详情展开）；面板档用 `--pin-panel` 固定为浮窗，点别处不会作废；`TIERS` 可只测几档；`make remote-measure` 在 M4 上跑同样的测量。
  - 注意：zsh 里 `log` 是内建命令，查统一日志要写 `/usr/bin/log`。
