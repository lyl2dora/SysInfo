# 功耗与散热模块实现规格

> 日期：2026-10-15 · 分支：`module/power-thermal`
> 依据：D14（完整版的内容）、D19、D20、D38、D40、D41、D43，**D44–D46（本模块的边界与拍板）**；能力边界的论证和实测数据见 `docs/design/power-thermal-boundary.md`（下称「边界稿」），本文只写怎么实现。
> 与决策档冲突时以决策档为准。实现中必须偏离本文的地方，记在文末「偏离记录」里。

## 1. 目标与验收

按 D14 做到完整版：采集器与自检、测试、菜单栏 widget、面板 tab、设置页、诊断页、历史与能耗，以及数值对照和开销实测。

验收清单（两台目标机都要做）：
1. `make build`、`make test`、`make test-hw`、`make remote-test` 通过，Swift 6 零警告。
2. 功率：
   - 整机功率与 `PowerTelemetryData` 的 60 s 均值逐分钟一致（偏差 <5%，丢失的分钟除外）。
   - SoC、GPU、DRAM 功率与边界稿 §2.1–§2.2 的探针读数一致；GPU 负载时 GPU 功率上升、CPU 空闲。
   - 把芯片档案换成不存在的芯片时：整机功率仍可用（运行时校验），SoC/DRAM 标「推断」，最热点显示「学习中」。
3. 最近 30 分钟：开机后第一个批次之前显示「等待首个批次」；批次到达后列出分部件平均功率，窗口起止时间与 PMGR 差分一致；重启 app 后立即显示上一批。
4. 散热：最热点与边界稿 §2.5 的键一致（M5 `TCMb`、M4 `TCMz`）；风扇转速、目标、模式正确（M5 `F0md`、M4 `F0Md`）；热压力徽标。
5. 能耗：按 1 Hz `PDTR` 积分写入历史库；app 退出再启动后，期间的能耗由累加器补上并标「系统累计」；面板显示今天、昨天、近 7 天的 kWh。
6. 诊断页：数据源状态、原始功率键、遥测逐分钟对账（丢失的分钟标出）、PMGR 最近一批、交叉核对比值、热点来源、传感器目录。
7. 菜单栏：5 个 widget（整机功率默认开，其余默认关），上下布局、宽度固定、自选颜色；点击打开面板的「功耗与散热」tab。
8. 开销：`make measure` 两台实测出厂默认（常驻）与本 tab 打开两档，按 D40 口径分别低于 0.5% 和 2%，结果写入 `docs/perf/power-thermal.md`。
9. 跨机：`make remote-cli` 跑通新增子命令；验收报告附两台对照表。

## 2. 仓库布局（新增与改动）

```
Packages/SysKit/Sources/
  SysModel/PowerMetrics.swift            本模块的 MetricID
  SysModel/ChipProfile.swift             新增可选的 system 段（SystemProfile）
  SysCollectors/Power/
    PowerRailCollector.swift             power.rail：PDTR + PowerTelemetryData（能耗、整机功率）
    PowerSensorCollector.swift           power.sensors：SoC / DRAM / 输入功率、最热点、风扇、低功耗模式
    GPUPowerCollector.swift              power.gpu：AGX「GPU Energy」单通道订阅
    PMGRBatchCollector.swift             power.pmgr：Energy Model 批次检测与分部件明细
    FanDiscovery.swift  HotspotLearner.swift  PMGRNaming.swift  TelemetryReader.swift
    PowerCrossCheck.swift                被动交叉核对（PZD1/AGX vs 批次、PDTR vs 遥测）
    SensorCatalog.swift                  sensors.catalog：诊断页的传感器目录（只在展开时采）
  SysCollectors/Resources/ChipProfiles/*.json   M5、M4 档案加 system 段
  SysStore/                              energy_minute / energy_hour / kv 三张表（schema 2）、EnergyIntegrator
  sysinfo-cli/Power.swift                power / pmgr / catalog / energy 子命令
App/
  MenuBar/StatusItemView.swift           由 CPUStatusItemView 通用化：一个 widget 一项，跨模块
  Panel/PowerPanelView.swift  Panel/PowerLiveViews.swift
  Settings/PowerSettingsView.swift
  Diagnostics/PowerDiagnosticsSection.swift
docs/perf/power-thermal.md
```

## 3. 数据模型

### 3.1 MetricID（发布后不改名）

| MetricID | 单位 | 来源 | 质量 |
|---|---|---|---|
| `power.system` | W | `PDTR` | measured；未知芯片在遥测核对通过前为 inferred |
| `power.wall` | W | 遥测 60 s：ΔWallEnergy × 3.6 / Δcount | estimated（D46：公式值） |
| `power.soc` | W | `PZC0` | measured；未知芯片 inferred |
| `power.dram` | W | `PZD1` | measured；未知芯片 inferred；交叉核对失败为不可用 |
| `power.gpu` | W | AGX `GPU Energy` 差分 | measured；交叉核对失败为不可用 |
| `thermal.soc.hotspot` | °C | 档案的聚合键 | measured；未知芯片学习中为 `unavailable(learning)` |
| `fan.<i>.rpm`、`fan.<i>.target` | rpm | `F<i>Ac`、`F<i>Tg` | measured |
| `fan.<i>.min`、`fan.<i>.max` | rpm | `F<i>Mn`、`F<i>Mx` | measured |
| `fan.<i>.mode` | 0/1 | `F<i>md` 或 `F<i>Md` | measured（0 自动，非 0 强制） |
| `power.lowPowerMode` | 0/1 | `ProcessInfo.isLowPowerModeEnabled` | measured |

- `PHPC`（SoC 实测输入）不定义为 MetricID：只进诊断读数（D44）。
- 热状态与热压力复用 CPU 模块的 `cpu.thermal.state`、`cpu.thermal.pressure`。
- PMGR 批次不是样本：`PMGRBatch`（窗口起止 + 各部件焦耳数，质量 `batched30min`）由采集器作为最新值暴露，并持久化到历史库（§6）。

### 3.2 芯片档案的 system 段（可选，schema 仍为 1）

```swift
struct SystemProfile: Codable {
    var systemPowerKey: String          // "PDTR"
    var socPowerKey: String?            // "PZC0"
    var socInputPowerKey: String?       // "PHPC"（诊断）
    var dramPowerKey: String?           // "PZD1"
    var hotspotKey: String?             // M5 "TCMb"，M4 "TCMz"
    var hotspotNote: String?            // M4：CPU 区断电时会停在旧值
    var pmgrComponents: [String: String] // 归一化名 → 通道名，例如 "gpu": "GPU0"（M5）/ "GPU"（M4）
    var pmgrClusters: [String: [String]] // 簇键 → PMGR CPU 通道，用于「模型口径」的 CPU 对照
    var catalogGroups: [String: String]  // 经负载验证的分组 → 键前缀，例如 "gpu": "Tg", "ane": "Ta"
    var placeholders: [Double]           // 传感器目录的占位值（M4 的 −4、0、1.5、2.2…）
}
```
- 解码时缺这一段视为没有（旧档案、本机校准结果照常可用）。
- 档案取值全部来自边界稿的实测（D33 的原则不变）。

## 4. 采集层

### 4.1 PowerRailCollector（`power.rail`，blocking）
- 每次读一个 SMC 键：档案 `systemPowerKey`，没有档案时用 `PDTR`。
- 遥测：距上次读取 ≥30 s 时读一次 `AppleSmartBattery.PowerTelemetryData`（只读 IORegistry 属性，0.15–0.23 ms）。计数器变化时算出：
  - 这一段的遥测均值 = ΔAccumulatedSystemPowerIn / Δcount（mW）；
  - `power.wall` = ΔAccumulatedWallEnergyEstimate × 3.6 / Δcount（W，estimated）。
- 输出 `power.system`、（有遥测更新时）`power.wall`。
- 对外暴露 `latestTelemetry`（累加器原值与时刻），供能耗补数和交叉核对使用。
- 自检：键存在，读数在 0.3–1000 W；遥测服务存在（不要求 `BatteryInstalled`）。
- 未知芯片：读 `PDTR`，质量 inferred；交叉核对（§4.6）连续 3 分钟偏差 <5% 后升为 measured。

### 4.2 PowerSensorCollector（`power.sensors`，blocking）
- 读 `socPowerKey`、`socInputPowerKey`、`dramPowerKey`、`hotspotKey` 与风扇键；读 `isLowPowerModeEnabled`。
- **FanDiscovery**（自检时做一次）：`FNum` 给出风扇数；每个风扇取 `F<i>Ac/Mn/Mx/Tg`，模式键依次试 `F<i>md`、`F<i>Md`，用 key-info 是否存在判断（D44）。`FNum` 为 0 或读不到时不输出风扇样本。
- 最热点：
  - 有档案：读 `hotspotKey`。读数在 −20–150 °C 之外，或等于档案占位值时为 `unavailable(sensorPowerGated)`。
  - 无档案：**HotspotLearner**。前 30 次采样（后台 10 s 一次，约 5 分钟）每次另读全部 `flt` 温度键，排除占位值与恒定键，统计「哪个键与逐次最大值相差 ≤0.05 °C」的比例；最高者 ≥90% 且样本 ≥20 时采用，否则继续学习。学习期间输出 `unavailable(learning)`。
- 诊断读数：`PHPC`、`PPSR`、`PMVC` 等原始功率键，热点键的来源（档案 / 学习 / 学习中）。
- 自检：档案里的键都存在（逐项判定，缺一个只隐藏对应指标，D24）；热点读数合理或为占位值。

### 4.3 GPUPowerCollector（`power.gpu`，inline）
- 从 IOReportHub 的「Energy Model」组里只选通道名为 `GPU Energy`、驱动名以 `AGX` 开头的通道，建单通道订阅（1.4–1.8 ms/次）。
- 功率 = Δ能量（按 unitLabel 换算成焦耳）/ Δ单调时钟。AGX 计数是累计量，采样间隔多长都不丢平均值。
- 自检：找到恰好一个通道；两次采样计数不倒退。

### 4.4 PMGRBatchCollector（`power.pmgr`，blocking，60 s）
- 订阅 Energy Model 中驱动名含 `PMGR` 的顶层通道与 CPU 簇级通道（按档案 `pmgrComponents` / `pmgrClusters`；无档案时按 **PMGRNaming** 的规则：去掉末尾的 `0` 后与已知名单匹配，不认识的原样列出）。
- 每次读取比较计数器：有 ≥3 个通道同时变化即视为新批次（通道少的芯片也能识别）。批次 = 本次快照与上一次变化快照之差；第一次变化只建立基线（开机后约 30–60 分钟才有第一批）。
- 对外暴露 `latestBatch: PMGRBatch?` 和上一份变化快照（持久化用，§6）。
- 自检：组可用、至少找到 `CPU Energy` 与 GPU 通道。

### 4.5 SensorCatalog（`sensors.catalog`，blocking，只在诊断页展开目录时，5 s）
- 首次全量枚举键名与 key-info（M4 约 120 ms，只做一次并缓存）；之后每次读 T/V/I/P/F 开头的数值键。
- 每个键的数据质量：有效 / 占位（档案 `placeholders`，或本次会话里「连续 ≥30 次精确不变、且等于档案外的常见占位值」）/ 恒定（会话内从未变化）/ 非温度（`T` 开头但读数 >150 或恒为小整数）。
- 分组只用档案 `catalogGroups` 与 CPU 簇键（D33）、热点键；其余显示原始键名（D44 PT6）。

### 4.6 PowerCrossCheck（被动交叉核对）
- 吃引擎的 tick 结果与 `latestBatch`，按批次窗口积分 `power.dram`、`power.gpu`、`power.system`：
  - `PZD1` / PMGR DRAM 在 0.98–1.02；
  - AGX / PMGR GPU 在 0.9–1.1；
  - 积分覆盖率不足窗口 90% 时记为「不确定」，不判失败。
- 每次遥测更新时比较这一段 `PDTR` 积分与遥测均值：偏差 <5% 为一致；计数增量 <55 记为「累加器丢失」。最近 60 段的结果供诊断页列出。
- 同一项连续两个批次失败时，对应指标改为 `unavailable(selfTestFailed("cross-check"))`，下一次通过即恢复。

### 4.7 采集器清单与默认需求

| 采集器 | 通道 | 菜单栏 | 面板本 tab 可见 | 后台（background 层） |
|---|---|---|---|---|
| `power.rail` | blocking | 整机功率 widget：常驻间隔 | 1 s | 1 s（能耗积分，D46；关闭能耗记录时不登记） |
| `power.sensors` | blocking | SoC 功率 / 最热点 / 风扇 widget：常驻间隔 | 面板间隔（默认 2 s） | 10 s |
| `power.gpu` | inline | GPU widget：常驻间隔 | 面板间隔 | 10 s |
| `power.pmgr` | blocking | — | 60 s | 60 s |
| `cpu.misc` | inline | — | 1 s（热状态） | CPU 模块已登记 |
| `sensors.catalog` | blocking | — | — | 诊断页展开目录时 5 s |

## 5. 能耗积分（D46，SysStore）

- **EnergyIntegrator**：吃 `power.system` 样本，按样本时刻做矩形积分：一个样本覆盖到上一个样本的时长，**单样本最多 1.05 s**；超出部分不外推，计入「缺口秒数」。按 UTC 分钟累加 `joules` 与 `covered_s`。唤醒后第一个样本丢弃。
- 与分钟聚合一起每 5 分钟提交到 `energy_minute`，整点后汇总进 `energy_hour`（永久保留）。
- **补数**：每次提交时把累加器原值、计数和墙钟写进 `kv`（`energy.anchor`）。app 启动后第一次拿到遥测时：
  - 同一次开机（`kern.boottime` 相同）且累加器没有倒退：缺口 [上次锚点, 现在] 的能量 = Δ累加器；
  - 开机时间变了：缺口改为 [开机, 现在]，能量 = 当前累加器值（累加器从开机起算）；
  - 缺口能量按时长均摊进所跨的小时，写入 `energy_hour`，`source = 1`（系统累计，可能偏低）。缺口短于 2 分钟时不补（与积分重叠）。
- 查询：今天、昨天、近 7 天 = `energy_hour` 之和 + 尚未汇总的 `energy_minute`；有 `source = 1` 的部分单独给出，界面标「含系统累计」。

## 6. 历史库（schema 2）

- 迁移 1 → 2 新增三张表：
  - `energy_minute(t PK, joules REAL, covered_s REAL)`，随分钟级 30 天过期；
  - `energy_hour(t, source, joules, covered_s, PK(t, source))`，永久；
  - `kv(key TEXT PK, value TEXT)`：能耗锚点、PMGR 上一批（JSON）与上一份变化快照。
- `HistoryCatalog` 增加：`power.system`、`power.soc`、`power.gpu`、`power.dram`（instant，W）、`thermal.soc.hotspot`（instant，degC）、`fan.<i>.rpm`（instant，rpm）。`power.wall`、风扇目标与模式、低功耗模式不入库。
- 设置「记录功耗与散热历史」关闭时这些指标不入库；「记录能耗」关闭时不登记 1 s 后台需求、不写能耗表。
- 导出：CSV 文件夹增加 `energy.csv`（小时，含 source），JSON Lines 增加 `energy` 记录类型；不含设备唯一标识。

## 7. App 层

### 7.1 菜单栏（D38、D41、D43）
- `CPUMenuWidget` 通用化为 `MenuWidget`，带 `module`（cpu / power）。CPU 四项的 rawValue、设置键、autosaveName 不变。新增：

| widget | 小标签 | 数值 | 定宽依据 | 采集器 | 默认 |
|---|---|---|---|---|---|
| `systemPower` | SYS | `48W`（<10 W 一位小数） | `99.9W` | power.rail | 开 |
| `socHotspot` | HOT | `92°` | `125°` | power.sensors | 关 |
| `socPower` | SOC | `12W` | `99.9W` | power.sensors | 关 |
| `gpuPower` | GPU | `21W` | `99.9W` | power.gpu | 关 |
| `fan` | FAN | `1000` | `9999` | power.sensors | 关；没有风扇时不出现 |

- 设置键：`menubar.power.<widget>.visible`、`menubar.power.<widget>.color`；autosaveName `<bundle id>.power.<widget>`。
- 功率值在 MetricStore 里做 τ = 2 s 的 EMA，菜单栏与面板概览读平滑值；图表与历史用原始值。
- `CPUStatusItemView` 改名 `StatusItemView`，按 widget 取标签、数值和定宽；非占用 widget 只有上下、左右两种样式。
- 点击功耗 widget 时面板预选「功耗与散热」tab（D21）。

### 7.2 面板「功耗与散热」tab
1. **概览**（自绘）：大号整机功率；右列 SoC 功率、SoC 最热点、风扇转速（无风扇时不画）；次要位置「墙插约 xx W（估算）」。
2. **历史图**：整机功率，可叠加 SoC 功率；纵轴按数据自动取整到 10/20/50/100 W；跨度同 CPU。CPU 的图表组件通用化为按 MetricID 与纵轴格式绘制。
3. **功率分解**（自绘）：CPU（专用轨合计，链接到 CPU tab）、GPU、DRAM 各一行，SoC 合计单独一行；不显示「其他」（D44）。
4. **最近 30 分钟**（SwiftUI，批次变化时刷新）：窗口起止、「X 分钟前更新」、各部件平均功率；CPU 行并排「专用轨实时均值」（窗口内 `cpu.power.total` 的积分 / 时长，来自历史库）；注明「Apple 功耗模型口径，每 30 分钟更新」。没有批次时显示「等待首个批次」。
5. **散热**（自绘）：最热点、风扇（转速 / 目标 / 范围百分比 / 自动或强制）、热压力徽标、低功耗模式徽标。
6. **能耗**（SwiftUI，每 60 s 重读）：今天、昨天、近 7 天 kWh；含系统累计时加注。

### 7.3 设置页「功耗与散热」（D41 分节）
- **菜单栏**：5 个 widget 的开关，打开后展开颜色、开销与预览。
- **采集**：本模块常驻间隔覆盖（`power.interval`）；面板间隔（`power.panel.interval`，1/2/5 s，标开销）。
- **面板**：图表默认跨度、是否叠加 SoC 功率。
- **历史**：记录功耗与散热历史（`history.power.enabled`）、记录能耗（`history.energy.enabled`，注明后台每秒读一个 SMC 键）。
- 「菜单栏」页的已开启总览、「历史与导出」页的记录状态总览改为跨模块。

### 7.4 诊断页
- 数据源状态与路径：各键（来自档案 / 默认 / 学习）、热点来源与 M4 的旧值说明、风扇模式键。
- 原始功率键：`PHPC`、`PPSR`、`PMVC`、`PZC0`、`PZD1`、`PDTR`。
- 遥测对账：最近 60 段的 PDTR 积分、遥测均值、偏差、计数增量，丢失的段标红。
- PMGR：最近一批的窗口与全部已订阅通道；交叉核对比值与结论。
- 传感器目录：默认折叠，展开时登记 `sensors.catalog` 需求。

## 8. 命令行

| 子命令 | 用途 |
|---|---|
| `power [--interval 1] [--count N] [--json]` | 整机 / SoC / GPU / DRAM 功率、最热点、风扇、低功耗模式、遥测 |
| `pmgr [--watch]` | 当前通道快照；`--watch` 等到下一个批次并打印分部件明细 |
| `catalog [--json]` | 传感器目录（键、值、质量、分组） |
| `energy [--db …]` | 历史库里的能耗汇总（默认读 `.dev` 数据目录） |
| `selftest` | 加入新数据源 |

## 9. 测试
- 纯函数单测：遥测换算与丢失检测、PMGR 批次检测与命名归一化、风扇模式键发现（大小写两种）、热点学习、占位值分类、能耗积分（1.05 s 上限、唤醒丢弃、跨分钟）、补数（同一开机 / 重启 / 倒退）、交叉核对判定、档案 system 段的解码（有 / 无）。
- 存储单测：schema 1 → 2 迁移、能耗表写入与小时汇总、导出 `energy.csv`。
- 硬件测试：档案键存在且读数合理；AGX 单通道订阅可建；遥测服务可读；Energy Model 组可订阅。

## 10. 实施顺序（分支内小步提交）
1. 模型、档案 system 段、四个采集器与 FanDiscovery、HotspotLearner、PMGRNaming；CLI `power`、`pmgr`；两台核对。
2. SensorCatalog 与 CLI `catalog`；PowerCrossCheck。
3. 历史库 schema 2、能耗积分与补数、导出；CLI `energy`。
4. App：widget 通用化与 5 个新 widget、面板 tab、设置页、诊断页、跨模块总览。
5. 两台截图自查、`make measure`、验收报告。之后交给用户验收，合并 `main` 前需要用户确认（D17）。

## 11. 偏离记录

（实现过程中偏离本文的地方记在这里：日期、内容、原因。）

- **2026-10-15 · §3.2 档案 system 段去掉 `pmgrClusters`**
  - 面板只需要「模型口径的 CPU 合计」与专用轨对照，用 `CPU Energy` 一个通道即可。M5 的簇级 PMGR 通道之间可能有重叠（边界稿 §2.4），按簇对照没有可靠口径，不做。
- **2026-10-15 · §4.4 PMGR 通道的选取**
  - 没有档案时只订阅 PMGRNaming 认得的顶层通道（CPU Energy、GPU、ANE、AVE、DRAM、AMCC、DCS、FAB、AFR、DISP、DISPEXT、ISP、MSR，末尾的 `0` 可有可无），认不出的顶层通道不列出。原文写「不认识的原样列出」，但「顶层」本身要靠名字判断，猜错会把子通道重复计入。
  - 新批次的判据是「≥3 个订阅通道同时变化」：只订阅十几个顶层通道后，按原探针的 ≥20 判不出来。
- **2026-10-15 · §4.1 遥测对账的第一段只建基线**
  - 启动后第一次读到的累加器值来自上一次发布，到下一次变化之间的差值覆盖整个 60 s 周期，而 PDTR 积分只从启动开始，第一段两者不可比（本机实测第一段偏差 −8.4%）。改为从第一次观察到计数变化起才对账。墙插估算按计数平均，不受影响，照常输出。
- **2026-10-15 · §4.2 诊断读数限频**
  - 原始功率键（PHPC、PPSR、PMVC 等 7 个）只给诊断页看，改为最多每 10 s 读一次。每次都读时，M4 上每个样本多约 0.5 ms。
- **2026-10-15 · §5、§6 补数按分钟存**
  - 原文是补数按小时均摊写进 `energy_hour`（source 1）。查询区间只覆盖某小时的一部分时（例如「今天」从 0 点算起，而缺口从 23:40 开始），按整小时折算会算错。改为写进新表 `energy_fill_minute`（与 `energy_minute` 对称，随分钟级 30 天过期），整点后再汇总进 `energy_hour` source 1。schema 2 还没有发布，直接改。
- **2026-10-15 · §6 GPU 功率按区间量入库**
  - AGX 是累计计数的差分，样本本身就是一段区间的平均功率，所以 `power.gpu` 用区间聚合（按重叠秒数拆到分钟），其余功率与温度仍是瞬时量。
- **2026-10-15 · §7 app 层的通用化**
  - `CPUMenuWidget` → `MenuWidget`（加 `module`），`CPUStatusItemView` → `StatusItemView`，`CPUStatusItemConfiguration` → `StatusItemConfiguration`，`CPUServices` → `AppServices`（新增 `power`），`CPUHistoryChart` → `HistoryChart`（按 `ChartSeries` 画占用或功率）。CPU 四个 widget 的设置键与 autosaveName 不变。
  - 模块页「菜单栏」节的 widget 行抽成 `WidgetSettingsRow`（`Settings/WidgetSettings.swift`），CPU 页与功耗与散热页共用。
  - 诊断页可见时另登记 `power.rail`、`power.sensors`、`power.gpu` 每秒一次（遥测对账要整机功率每秒采样）。
  - 新增启动参数 `--panel-tab=<cpu|power>`（截图与开销测量用）；`scripts/measure-overhead.sh` 增加 `power` 档。
- **2026-10-15 · §4.6 GPU 交叉核对要求最低负载**
  - M5 空闲时 PMGR GPU 窗口均值只有 0.033 W，AGX ÷ PMGR = 1.074，已贴近 1.1 的上限；满载时是 1.002。连续两次误判会停用 GPU 功率，所以窗口均值低于 0.3 W 时这一批记为「不下结论」。DRAM 不受影响（空闲时 0.997）。
- **2026-10-15 · D47：面板只显示被点击 widget 所属的模块（验收时用户改定）**
  - 去掉面板顶部的模块切换和顶栏中间的「SysInfo」标题；功耗面板去掉「按簇查看 CPU 功耗」链接。
  - 从一个 widget 点到另一个时原地换内容。用户实例的日志显示原先的过程是：全局鼠标监视器先把面板当「点了别处」隐藏，约 12 ms 后系统开启新 session，再过约 45 ms 新内容才显示，中间约 60 ms 空白。现在：
    - 点到本 app 的另一个 widget 时只记下「要切换」，不隐藏；
    - 系统先结束旧 session、再开始新 session，旧 session 结束时面板保留（0.5 s 内新 session 没来才隐藏）；
    - 新 session 开始时，在同一次提交里换内容、改尺寸和位置。
  - 用每 5 ms 一次的窗口轮询核对（本机，SYS ↔ CPU 各两次）：面板始终在屏幕上，一步换成新模块的尺寸和位置，没有空白帧。
  - 「功耗与散热」面板里风扇行、30 分钟卡片的行数在视图创建时就确定，能耗卡片固定三行加一行说明（读到之前显示「—」），切过来时高度不再先矮后高。
- **2026-10-16 · Top N 打开时的闪烁（验收时用户发现，参考 Stats 的做法）**
  - 现象：从 SYS 直接点到 CPU，Top N 先显示「等待数据…」，约 2–3 s 后出现行。行到达的那一帧内容已经变高、窗口还是旧高度，SwiftUI 把内容垂直居中，整块内容上下跳一下，下一轮改高后又跳回来。
  - Stats 的做法：每个模块的弹窗启动时就按设置的行数建好固定 22 pt 的进程行，数据到达只改文字；进程列表在弹窗出现时立即读一次 `ps`（`pcpu` 是衰减均值，一次就有数，但不是区间占用）。
  - 改法：
    - 第一版立即出数：Top N 激活时，若 AppSampler 的 `latestWindow` 不超过 15 s（后台历史每 10 s 扫一次），直接用它组装，仍是准确的区间占用；之后按面板的 2 s 刷新；
    - 固定行位：按设置的行数画行位，每行都有副标题行（没有时留空），空行位同样高度；数据到达只填内容，面板高度不变。展开成员仍会改高度（用户主动操作）；
    - 面板内容顶部对齐：任何「内容先变、窗口后改」的情况只是底边伸缩，内容不再整体跳动。
  - 复测（本机，先 SYS 再 CPU）：切换后 0.35 s 内 Top N 已显示 5 行，之后 4.5 s 内面板高度没有变化。
