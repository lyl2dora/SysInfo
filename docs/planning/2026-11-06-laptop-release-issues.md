# 笔记本上运行 Release 1.1.0 的问题清单（L01–L14）

> 日期：2026-11-06。Release 1.1.0（build 335）第一次跑在带电池和刘海屏的机器上（Mac17,8，M5 Pro，macOS 27.2 26B123），对照 `v1.1.0` 源码排查。
> 除 L01、L02 外都只入档，择期修（2026-11-06 用户决定）。需要取舍的条目修复时先讨论，结论追加为新的 D 条目；本文件只记录问题与状态，**以决策档为准**。

路径约定：`SysCollectors/…`、`sysinfo-cli/…` 都在 `Packages/SysKit/Sources/` 下；`App/…` 在仓库根目录下；测试在 `Packages/SysKit/Tests/SysCollectorsTests/` 下。行号以分支 `fix/laptop-system-power` 为准。

状态：**已修未合并**（附提交）· **待修** · **待验证**（缺实测，不一定要改代码）· **待定**（要用户决定）。依据：**实测**（这次在真机上看到）· **推断**（只来自读代码）。

## 总表

| 编号 | 问题 | 严重度 | 依据 | 状态 |
|---|---|---|---|---|
| L01 | 整机功率读 `PDTR`，它只是电源输入：由电池供电时接近 0，自检不过，菜单栏 `SYS` 显示「—」 | 高 | 实测 | 已修未合并 f8e3dba（D107） |
| L02 | 能耗历史随 L01 中断（积分与补数都是 0 行）；补数的累加器也只算电源输入，比整机负载低约一半 | 高 | 实测 | 已修未合并 f8e3dba（D107） |
| L03 | 常驻开销超预算：合并模式、面板关闭时考核值 0.47%（预算 0.2%），指令数约为台式机记录的 6 倍，原因未定位 | 高 | 实测 | 待修（先测量） |
| L04 | 修复后的 `PSTR` 只在由电池供电时验证过；充电中、稳定由电源供电、拔掉电源都没测，对账有一段偏差 +13.3% | 中高 | 实测 + 缺口 | 待验证 |
| L05 | 内置 SD 读卡器没插卡也算一块物理盘：清单与面板多出「?」，历史库每分钟多记读写 0，硬件测试失败 | 中 | 实测 | 待修 |
| L06 | 这台机器的 SMC 没有 `PPSR`，系统 build 也不在已验证列表，`cpu.sensors` 一直是「降级」，两个硬件测试失败 | 中 | 实测 | 待修 |
| L07 | 刘海屏菜单栏空间不够时 item 被收进系统的 `«` 溢出区，出厂 widget 数量没有按刘海屏复核（K41、D51） | 中 | 实测（两个实例并存） | 待定 |
| L08 | 电池 widget 接着电源就显示闪电，电量高于充电上限、实际在放电时也一样（D88 的待核对项） | 中低 | 实测 | 待定 |
| L09 | 由电池供电时，面板「墙插约 0.53 W（估算）」紧挨整机 8.28 W，读起来像矛盾；公式也可能不适用于笔记本 | 中低 | 实测 | 待定 |
| L10 | 内置电池的面板内容标着「未在真机验证」（D84），现在有真机了，还没验证 | 中低 | 实测 + 缺口 | 待验证 |
| L11 | SwiftUI 重入布局 Fault：面板隐藏后约 0.1 s 出现 1 次 | 低 | 实测（原因未证实） | 待修 |
| L12 | 内存 footprint 约 81 MB、峰值约 180 MB，高于记录的 21–39 MB | 低 | 实测（13 分钟） | 待验证 |
| L13 | `sysinfo-cli power` 的遥测对账行每段打印两次 | 低 | 实测 | 待修 |
| L14 | 目标设备清单未定：Mac17,16 是否还算目标设备（D108）；这台没有 `Config/remote.local.mk`，修复没做 M4 对照 | 中 | 实测 | 待定 |

## 详情

### 已修未合并

- **L01** `SysCollectors/Power/PowerRailCollector.swift`、`SysCollectors/Power/PowerSupport.swift`。同一时刻 `PDTR` = 0.08 W、`SystemPowerIn` = 74 mW、`PSTR` 与 `SystemLoad` 同量级；整机超过 100 W 时 `PDTR` 仍是 0.07–0.08 W；遥测刷新的一刻 `PSTR` 与 `SystemLoad` 同为 27.37 W。修复前自检按 10、20、40…… 秒的间隔反复失败。**风险（推断，修复前的代码）**：自检通过后运行中只查 0–2000 W，拔电后会显示约 0 W 且标为实测。分支合并并发版之前，日用的 Release 仍有这个问题。
- **L02** `SysStore/HistoryRecorder.swift:377`、`SysStore/Energy.swift`。补数只在有整机功率样本时才触发，所以一起断了。本次开机累计 `AccumulatedSystemPowerIn` 43.6 kJ，`AccumulatedSystemLoad` 89.3 kJ。修复后 Debug 版实测：3 分钟有积分入库，补数约 34.4 Wh / 7800 s（均值约 15.9 W）。

### 开销

- **L03** 测量（60 s，面板关闭，整机 CPU 约 8–9%）：116 M 指令/s，原始 CPU 4.39%，参照值 24.94 G/s，考核值 0.47%。对照：`docs/perf/release-1.0.0.md` 里 Mac17,16 合并模式 19.4 M 指令/s、1.02%、0.165%。
  - 采样：主线程占活跃采样 238/271，其中 193 个在系统的 `-[NSStatusItem _updateReplicants]`，分别走 `CA::Transaction::flush` 与 `_cacheDisplayInRect` 两条路径。`App/MenuBar/MergedStatusItemView.swift:4` 的「只重绘变化的那一段」省不下这部分。
  - **不能直接比较**：两边的机型、系统（27.2 与 27.0.1）、widget 数（6 段与 5 段）都不同，分不清主因。
  - 下一步：用户退出 Release 后，在这台机器上跑 `make measure`（脚本在有其他实例时拒绝执行），对比单 item 与合并、有无电池 widget；再判断是不是 27.2 的变化。D89 待复核的「有 UPS 或电池时多一个 widget」的开销也一并测。

### 待验证

- **L04** 对账 3 段：+13.3%（当时另有构建在跑，负载剧烈变化）、−0.6%、−0.5%。三种状态要分别看 `PSTR`、`SystemLoad`、`PDTR`：电量降到充电上限后的稳定供电不用插拔；充电和拔电要用户配合（D18）。其他带电池的芯片没有测过，靠自检和对账把关。
- **L10** `App/Panel/DevicesPanelView.swift`。CLI 读到 `InternalBattery-0`、外接电源、电量正确；面板卡片还没看。验证后去掉「未在真机验证」的标注。健康度、循环次数（D84 PD1 说等有带电池的设备再做）是否现在做，到时一起定。
- **L12** 13 分钟内在 74–81 MB 之间，没有线性增长的迹象；这段时间打开过面板和设置，不足以排除慢速泄漏。记录值是 `make measure` 的短时测量，口径不完全一样。需要一次面板关闭的长时间观察。

### 待修

- **L05** `SysCollectors/Storage/` 的 `DiskInventory`。`sysinfo-cli storage` 显示「物理盘 2 块」，第二块是 `? · Built In SDXC Reader`，没有 BSD 名和容量。`StorageTests.swift:347、348`（`findsPhysicalDisksWithStatistics`）失败；`StorageTests.swift:386`（`focusLimitsReadsToFocusedDisks`）也失败，可能同因，未证实。修之前要想清楚插卡后的行为。
- **L06** `SysCollectors/Sensors/SensorCollector.swift:200–219`，档案 `AppleT6050PMGR.json`。`PPSR` 是档案里的 `sharedRails`，只进诊断，不参与簇功耗合计；温度与簇功耗照常输出，所以读数不受影响，只是状态一直降级。失败的测试：`PrivateLayerHardwareTests.swift:103`、`HardwareTests.swift:91`。档案描述也还写着 Mac17,16。要定的是：同一块芯片的档案怎么表达「共享轨随机型不同」，以及 26B123 怎么加进已验证列表。
- **L11** 19:34:35 出现 `NSHostingView is being laid out reentrantly`，紧接 `-layoutSubtreeIfNeeded` 的 AppKit 报错。`App/Panel/PanelController.swift:720`（`fitToContent`）与 `:741`（`fittingSize`）有嫌疑，未证实。只出现过 1 次，要先能复现。
- **L13** `sysinfo-cli/Power.swift:58`。判断「本段刚结束」的时间窗比采样间隔宽，同一段会连续命中两次。只影响 CLI 输出。

### 待定（要用户决定）

- **L07** Release 与 Dev 同时运行时，Dev 的 item 大多进了 `«`，第三方 item 也被挤掉。两个实例并存放大了问题，不能直接算作出厂表现；要在只有一个实例、出厂配置下看。D51 只定了数量，K41 写明出现刘海屏笔记本要重新考虑。
- **L08** D88 写明「接着电源时加闪电」，并留了「以用户在 MacBook 上看到的为准」的待核对项。系统自己此时显示 `AC attached; not charging`。要定的是与系统保持一致，还是如实反映放电。
- **L09** `App/Panel/PowerLiveViews.swift:35`。D46 的公式（1.035 × 直流 + 1.6 W）是台式机上得出的；这台由电池供电时遥测 `WallEnergyEstimate` 约 0.15 W。数值本身是对的（墙插确实几乎没出力），要定的是这时隐藏还是改说法。
- **L14** D108 留了 Mac17,16 的去留。M4 对照缺的是这台机器的本地配置（`Config/remote.local.mk`、`CLAUDE.local.md`，都不进库），补上后 `make remote-*` 才能用；L01 的台式机路径没有在 M4 上实测。

## 核对过、不算问题的部分

- `cache_delete` 日志（每分钟或每两分钟一轮，共 1200 多行）：来自设计内的可清除空间查询，最多 60 s 一次（`StorageCapacityCollector.purgeableCacheSeconds`，审计 A39）。
- CoreSpotlight donation 失败（`CSIndexErrorDomain -1000`）：项目代码里没有相关调用，应是系统框架行为。
- `MTLCompilerService` 与着色器编译：只出现在启动那一分钟。
- 状态栏 scene 报错（`Unhandled disconnected scene` 等 52 条）：集中在 19:34–19:35，同时段有 item 增删，疑似切换合并模式所致；之后窗口数回到一个 item 的 4 个，没有残留。
- 接着电源却放电：用户设的充电上限带来的正常现象，不是硬件或 SysInfo 的问题。
- 满载时的 CPU 97%：`top` 与 CLI 一致，读数正确，负载来自其他进程。
- CPU 温度约 40 °C 而 SoC 热点约 50 °C：`Tp**` 原始键与 CPU 读数一致，热点 `TCMb` 贴近 `TVD*`，没有发现读错键的证据。
- 风扇 0 rpm：实测风扇停转，`F0Mx`、`F1Mx` 正常（5349、5777）。
- 网络：运行中没有打开的套接字，符合 D76、D10。
