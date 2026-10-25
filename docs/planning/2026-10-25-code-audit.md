# 代码审计问题清单（A01–A64）

> 日期：2026-10-25，审计基线 main @ 77798a3。全仓只读审计，按 7 个范围分别审读（采样引擎与私有层；CPU、内存、GPU；功耗、传感器、网络；存储、应用活动与数据模型；历史库；App 核心、菜单栏与小组件；面板视图、设置、CLI 与脚本），抽查的条目已对照源码复核。
> 结论只来自读代码，除标注外未在真机上复现。需要用户取舍的条目修复时先讨论，结论追加为 D95 起的新条目；本文件只记录问题与状态，**以决策档为准**。

路径约定：`SysCollectors/…`、`SysModel/…`、`SysStore/…`、`sysinfo-cli/…` 都在 `Packages/SysKit/Sources/` 下；`App/…`、`Widgets/…`、`scripts/…` 在仓库根目录下。行号对应审计基线。

状态：**已修**（附提交）· **待修**（按批次）· **暂缓**（影响小，有空再做）。

## 总表

| 编号 | 问题 | 严重度 | 状态 |
|---|---|---|---|
| A01 | 内存：host_statistics64 被自检停用后，从不读 `vm.compressor_bytes_used`，被压缩永远不可用、已用偏低 | 高 | 已修 6c42492 |
| A02 | 历史库：先出队再写库，写库失败丢最多 5 分钟数据；能耗另开事务，不原子 | 高 | 已修 f6e6119 |
| A03 | 历史库：事务回滚后 metric / app ID 缓存不回滚，rowid 复用时两个指标共用一行 | 中 | 已修 f6e6119 |
| A04 | IOReport `sampleDelta()` 失败时基线照样前移，调用方时间戳不动，下一帧功率与速率约减半 | 中 | 已修 5694f84 |
| A05 | SMC 类采集器全部读失败时报 degraded，K19「运行中连续越界」复检永远不触发 | 中 | 已修 0b10325 |
| A06 | GPU 功率：读失败报 ok 且不出样本；负差值或通道缺失时 `power.gpu` 静默缺失 | 中 | 已修 0b10325 |
| A07 | SMCReader 连接失效后永不重连 | 中 | 已修 0b10325 |
| A08 | 自检结果不更新 `health.status`，没有需求的采集器自检失败后仍显示正常 | 低 | 已修 0b10325 |
| A09 | 驻留增量被钳为 0（CPU 簇频率、GPU 活跃与频率、GPU 诊断） | 中 | 待修 · 第一批 |
| A10 | 媒体引擎、中断来源：只跳过负通道仍出部分和；媒体引擎空闲底数被永久拉低 | 中 | 待修 · 第一批 |
| A11 | 小组件：陈旧阈值没算降频倍数，降频时 SoC 温度、GPU、磁盘容量每隔一次写成「—」 | 中高 | 待修 · 第一批 |
| A12 | UPS：指定集合找不到时借用任意集合的同名元素，电池电压可能显示为市电值 | 中 | 待修 · 第一批 |
| A13 | 网络：用户网桥含以太网成员时物理合计重复计数（违反 D60） | 中 | 待修 · 第一批 |
| A14 | SMART：自检判为不合理的盘，坏读数仍留在 `latestRecords` 被面板显示 | 中高 | 待修 · 第一批 |
| A15 | SMART：无综合温度的哨兵 -273 被判为不合理，整盘不可用 | 中低 | 待修 · 第一批 |
| A16 | 散热卡片：无热状态时显示绿色「热状态正常」，缺风扇模式时显示「自动」 | 中 | 待修 · 第一批 |
| A17 | Top N 与应用详情：缺失的磁盘、GPU 值显示为 0；辅助槽不可信时只屏蔽 CPU 能耗 | 中 | 待修 · 第一批 |
| A18 | `cpu.freq` 自检失败只返回空样本，不逐簇给原因 | 低 | 待修 · 第一批 |
| A19 | `Sample` 不拦非有限值；`memory.usage` 除以 `hw.memsize` 前不判零 | 低 | 待修 · 第一批 |
| A20 | Top N 悬停冻结残留：悬停时进详情或 Esc 关面板，再开一直空表 | 中高 | 待修 · 第二批 |
| A21 | 网络 tab 的 CoreWLAN 需求不跟 Wi-Fi 开关变化，关掉 Wi-Fi 后仍每 5 s 读（违反 D10） | 中高 | 待修 · 第二批 |
| A22 | `WiFiCollector.selfTest()` 在启动、唤醒时调用 CoreWLAN（违反 D10） | 低 | 待修 · 第二批 |
| A23 | HistoryRecorder `applyDemands` 的 actor 重入，`stop()` 后仍有后台需求存活 | 中 | 待修 · 第二批 |
| A24 | 已有内置电池时插 UPS，电源设备 tab 不登记 UPS 需求 | 低 | 待修 · 第二批 |
| A25 | 「中断来源」需求只靠 SwiftUI onAppear / onDisappear，原地换内容时顺序不确定 | 低 | 待修 · 第二批 |
| A26 | Top N 回退刷新不检查 `isActive`，关面板后写回旧行 | 低 | 待修 · 第二批 |
| A27 | Top N 成员 CPU / 磁盘基线与 coalition 窗口不对齐；`pruneCaches` 是空操作 | 中高 | 待修 · 第二批 |
| A28 | 更新器：检查失败后每小时重试，不是每周（D76） | 中 | 待修 · 第三批（需决策） |
| A29 | 更新器：两段版本号拼出的资产名与 CI 产物不符；带后缀的当前版本按 0.0.0 比较 | 低 | 待修 · 第三批 |
| A30 | 导出脱敏不完整：可执行路径带出家目录用户名、模拟器与转移路径 UUID、卷名 | 中 | 待修 · 第三批（需决策） |
| A31 | 自定义延迟地址每敲一键即生效；可填局域网地址，与隐私页文案矛盾 | 中 | 待修 · 第三批（需决策） |
| A32 | 引擎 `rearm()` 会覆盖已到时间、尚未触发的 tick | 中 | 待修 · 第四批 |
| A33 | 跨睡眠时按睡眠前的 tick 序号执行，被动核对把窗口算成睡眠时长 | 低 | 待修 · 第四批 |
| A34 | 墙钟跳到未来后小时汇总与清理停摆；往回拨时新分钟落进已汇总小时 | 中 | 待修 · 第四批 |
| A35 | 能耗补数按 boottime 差 < 2 s 判同一次开机，校时可能被误判为重启而重复计入（未实测） | 中 | 待修 · 第四批 |
| A36 | SQLite `run` / `query` 中 step 出错不复位，读事务挂住，WAL 无法收缩 | 中 | 待修 · 第四批 |
| A37 | 清除每应用数据后不清 `openSpans`，进行中的断言不再记录 | 低 | 待修 · 第四批 |
| A38 | 模块历史全关时 `lastRun` 不更新，重开后首个样本回摊到关闭期间 | 低 | 待修 · 第四批 |
| A39 | 可清除空间为 0 时不进缓存，每次采样多花 15–60 ms | 中 | 待修 · 第四批 |
| A40 | 存储、网络二级页 body 里读 `recentPoints`，每 tick 重建整页 | 低 | 待修 · 第四批 |
| A41 | 磁盘键用序列号 + 型号，同款 USB 桥报同一假序列号时冲突 | 中 | 待修 · 第四批 |
| A42 | 盘插拔通知与重新枚举有竞态；首次匹配时 driver 可能未挂上 | 低 | 待修 · 第四批 |
| A43 | SMART 自检时所有盘恰好被独占，整个采集器判为不可用到下次唤醒 | 中低 | 待修 · 第四批 |
| A44 | measure-overhead.sh：「面板中途关闭则作废」只查两档，且依赖不落盘的 info 日志 | 中 | 待修 · 脚本 |
| A45 | remote-app.sh：连跑两次后清场漏删（违反 D39）；`grep -q Preferences` 误匹配；`$*` 未加引号 | 中 | 待修 · 脚本 |
| A46 | 频率主动核对允许 10% 时间在别的簇，阈值 ±5% 却是必需项，可能误判整体不可用 | 低 | 暂缓 |
| A47 | 核被停用时每帧计 droppedCores，整机占用一直标估算 | 低 | 暂缓 |
| A48 | GPU 温度用 `Dictionary(uniqueKeysWithValues:)`，档案键重复即崩溃 | 低 | 暂缓 |
| A49 | 无 Group ID 无 Name 的配件键用 `UUID()`，每次重建都是新设备 | 低 | 暂缓 |
| A50 | 按 IFMIB index 读数不核对接口名，index 复用时出现假速率 | 低 | 暂缓 |
| A51 | PMGR 批次窗口用检测时刻，DRAM ±2% 区间可能误判（推断） | 低 | 暂缓 |
| A52 | 只有 IPv6 链路本地网关且不带 scope 时，网关延迟全丢（未核实） | 低 | 暂缓 |
| A53 | 小组件快照并发写入直接丢弃，刷新按钮可能无效 | 低 | 暂缓 |
| A54 | 单实例：拿锁到注册「重开」通知之间的窗口里，二次启动的通知丢失 | 低 | 暂缓 |
| A55 | 频繁 flush 切片当前分钟，n 取整放大短片段权重，`total()` 偏高 | 低 | 暂缓 |
| A56 | 同应用同名同类型两条断言 ±1 s 内开始时合并成一行 | 低 | 暂缓 |
| A57 | 断言与 UPS 快照各起 Task，可能乱序处理 | 低 | 暂缓 |
| A58 | `total()` 跨小时表时首尾取整不对称 | 低 | 暂缓 |
| A59 | 网络历史图不跟随 bit/byte 设置；无障碍标签用了磁盘图文案 | 低 | 暂缓 |
| A60 | 历史图横轴中点标签整数截断（「7 分前」「3 天前」） | 低 | 暂缓 |
| A61 | Top N 排序无次键，并列项顺序闪动 | 低 | 暂缓 |
| A62 | 阻塞采集器建基线期间引擎每秒空唤醒，`skippedBusyCount` 虚高 | 低 | 暂缓 |
| A63 | 阻塞通道上的 sample 与 actor 上的 selfTest / resetBaseline 可并发，与协议注释不符 | 低 | 暂缓 |
| A64 | 其他小项：`exclusiveAccess` 常量实为 `kIOReturnNoResources`；InstanceLock 的 errno 读取时机；`make stop` 无产物时静默失败；check-private-imports 不扫 .cpp / 符号链接、原始字符串解析有缺口；同 socID 只看第一个档案；build 号变化复检只记日志 | 低 | 暂缓 |

## 位置与触发场景

### 已修

- **A01** `SysCollectors/Memory/MemoryCollector.swift:264`。回退条件写成 `statisticsOK && statistics == nil`，注释说的回退场景却是 `statisticsOK == false`；自检里的页面队列之和同样漏算。
- **A02** `SysStore/HistoryRecorder.swift:557`。`aggregator.take()` / `energy.take()` 取走后再写库，catch 不放回。修法：`pending` 后写库，成功才 `discard`；持续失败时内存最多留 60 分钟。
- **A03** `SysStore/HistoryStore.swift:237`。`metricRowID` / `appRowID` 在事务内插入后立刻写缓存。修法：事务失败时恢复事务前的缓存快照。
- **A04** `SysCollectors/Private/IOReportHub.swift:236`。`defer { previous = current }` 写在 delta 失败的 guard 之前；GPU 诊断三个订阅共用一个时间戳，任一失败时全部重建基线。
- **A05** `SysCollectors/Engine/SamplingEngine.swift:432` 只对 `.unavailable` 计数；`SensorCollector`、`GPUTemperatureCollector`、`PowerSensorCollector`、`PowerRailCollector` 改用 `CollectorStatus.reads(attempted:failed:)`。
- **A06** `SysCollectors/Power/GPUPowerCollector.swift:169、175`。
- **A07** `SysCollectors/Private/SMCReader.swift:184、211、238`。IPC 层失败时关闭连接，下次调用重新打开。
- **A08** `SysCollectors/Engine/SamplingEngine.swift:410`。

### 第一批：数据正确性

- **A09** `SysCollectors/CPU/FrequencyDiscovery.swift:197`、`SysCollectors/GPU/GPUSupport.swift:93`、`SysCollectors/GPU/GPUDiagnosticsCollector.swift:151`。驻留计数复位或部分回退时，结果仍标 measured。CPUTickMath 的 `counterReset` 是正确做法。
- **A10** `SysCollectors/GPU/MediaEngineCollector.swift:93`、`SysCollectors/CPU/InterruptDeviceCollector.swift:104`。avd 有多个中断源，其中一个复位 → 本帧速率偏低 → `InterruptBaseline.observe` 取运行期最小值 → 之后 `media.decode.rate` 空闲时也大于 0。
- **A11** `App/Widgets/WidgetSnapshotWriter.swift:261`（阈值 `interval + 30`）；`SysCollectors/Engine/Schedule.swift:16`（`slowed(2)` 对 background 层同样生效）。
- **A12** `SysCollectors/Devices/UPSReportLayout.swift:90`；调用在 `UPSTelemetryCollector.swift:386、400、403`。`compare()` 只在 AC 在线时核对电量与输入电压，拦不住电池电压串位。
- **A13** `SysCollectors/Network/NetworkInventory.swift:167`（Bridge 一律算物理接口，成员只排除 ThunderboltIP / USBDeviceNCM）；合计在 `NetworkIOCollector.swift:137`。
- **A14** `SysCollectors/Storage/SMARTCollector.swift:296`（`read()` 无条件写 `records`）、`:165`（自检先读后判）；面板在 `App/Panel/StoragePanelView.swift:250、403、710、762` 直接读。
- **A15** `SysCollectors/Storage/SMARTCollector.swift:352`（0 K → -273）与 `:325`（`< -20` 判不合理）矛盾，`:309` 又把 -273 当「不支持」。
- **A16** `App/Panel/PowerLiveViews.swift:151、169`。
- **A17** `App/Panel/TopNSection.swift:184、186`、`App/Panel/AppDetailView.swift:65`、`SysCollectors/Apps/TopNBuilder.swift:456、499`。同文件成员行（`:194`）已正确显示「—」。
- **A18** `SysCollectors/CPU/CPUFrequencyCollector.swift:137`。
- **A19** `SysModel/Sample.swift:60`、`SysCollectors/Memory/MemoryCollector.swift:274`。

### 第二批：需求生命周期

- **A20** `App/Panel/TopNSection.swift:72`（`.onHover { model.isFrozen = $0 }`）；`App/Support/AppServices.swift:288`（`setActive` 不重置）。
- **A21** `App/Panel/PanelController.swift:538`（`hasWiFi` 只在 `updateDemands` 时算一次）；`App/Support/AppServices.swift:145`（`structureChanged` 不看 `isActive`）。
- **A22** `SysCollectors/Network/WiFiCollector.swift:40`。
- **A23** `SysStore/HistoryRecorder.swift:235、316、512`。
- **A24** `App/Support/PowerDevicesModel.swift:54`、`App/Panel/PanelController.swift:554`。
- **A25** `App/Panel/CPUPanelView.swift:128`、`App/Panel/PanelController.swift:611、633`。
- **A26** `App/Support/AppServices.swift:417`。
- **A27** `SysCollectors/Apps/TopNBuilder.swift:397、480、539、552`。

### 第三批：策略与隐私

- **A28** `App/Support/Updater.swift:82、101`（`lastCheck` 只在成功分支写）。
- **A29** `SysModel/AppUpdate.swift:27、80`；`scripts/build-release.sh:32`；`App/Support/Updater.swift:99`。
- **A30** `SysStore/HistoryExporter.swift:234、247、314、343`；身份键来源 `SysCollectors/Apps/AppIdentity.swift:86`。与 `redactingUUIDs` 注释及设置页「不含硬件 UUID」的文案不符。
- **A31** `App/Settings/NetworkSettingsView.swift:55`、`App/SysInfoApp.swift:317`、`App/Settings/SettingsRootView.swift:716`。

### 第四批：健壮性与开销

- **A32** `SysCollectors/Engine/SamplingEngine.swift:255`、`SysCollectors/Engine/Schedule.swift:107`。
- **A33** `SysCollectors/Engine/SamplingEngine.swift:274、281、299`、`SysCollectors/Validation/PassiveValidator.swift:75、90、98`。
- **A34** `SysStore/HistoryStore.swift:329`、`SysStore/Energy.swift:153`、`SysStore/HistoryRecorder.swift:577`。
- **A35** `SysStore/Energy.swift:90`；`SysCollectors/Power/PMGRBatchCollector.swift:163` 同款。
- **A36** `SysStore/SQLiteDatabase.swift:130`。
- **A37** `SysStore/HistoryRecorder.swift:646`、`SysStore/HistoryStore.swift:364`。
- **A38** `SysStore/HistoryRecorder.swift:348`、`SysStore/MinuteAggregator.swift:140`。
- **A39** `SysCollectors/Storage/StorageCapacityCollector.swift:72、148`。
- **A40** `App/Panel/StoragePanelView.swift:194`、`App/Panel/NetworkPanelView.swift:136`。
- **A41** `SysCollectors/Storage/DiskInventory.swift:180、256`。
- **A42** `SysCollectors/Storage/DiskInventory.swift:76、114`。
- **A43** `SysCollectors/Storage/SMARTCollector.swift:165、213`。

### 脚本

- **A44** `scripts/measure-overhead.sh:225`；Stats 只在开始时检查一次。
- **A45** `scripts/remote-app.sh:84、85、107`。

### 暂缓

A46 `CPU/CPUFrequencyCollector.swift:330`；A47 `CPU/CPUTickMath.swift:107`；A48 `GPU/GPUTemperatureCollector.swift:99`；A49 `Devices/PowerSourceMonitor.swift:237`；A50 `Network/NetworkInventory.swift:375`；A51 `Power/PMGRBatchCollector.swift:181、217`；A52 `Network/LatencyCollector.swift:131、347`；A53 `App/Widgets/WidgetSnapshotWriter.swift:160`；A54 `App/SysInfoApp.swift:42、150`；A55 `SysStore/MinuteAggregator.swift:224`；A56 `SysStore/AppHistory.swift:130`；A57 `SysStore/HistoryRecorder.swift:422、478`；A58 `SysStore/HistoryStore.swift:439`；A59 `App/Panel/NetworkPanelView.swift:33`、`App/Panel/LiveViews.swift:429`；A60 `App/Panel/HistoryChart.swift:155`；A61 `Apps/AppSampler.swift:232`、`Apps/TopNBuilder.swift:299`；A62 `Engine/Schedule.swift:63`；A63 `Collector.swift:7`；A64 `Storage/SMARTCollector.swift:95`、`SysStore/InstanceLock.swift:29`、`scripts/stop-dev.sh:12`、`scripts/check-private-imports.sh:45、72`、`Profiles/ChipProfileStore.swift:91`、`App/SysInfoApp.swift:377`。

## 审计中核对过、没有问题的部分

CPU tick 差分与回绕；页面计数走 `vm.page_*`；GPU 利用率不用 `Device Utilization %`；AGX 能量单位与时间基；mach timebase 128 位换算；SMC 字节序、类型与 result 字节检查；C 层 CF 所有权与结构体大小；拓扑按 die / cluster 分组，没有写死 M5 的值；PDTR 积分与 D44、D45、D46；HID 限定 0x84、按 registry ID 作键；电源按 Type 归类；网络只用 IFMIB 64 位计数，不用 `ifi_baudrate`；没有 nettop、`system_profiler`、SSID；SQLite 绑定与迁移；UTC 分钟存储；flock 锁语义；Debug 与 Release 的 defaults 域、数据目录隔离；菜单栏宽度固定；登录项出厂不注册；更新器只访问本仓库并校验签名；stop-dev 只结束 Debug 实例；字节、比特、功率单位换算。
