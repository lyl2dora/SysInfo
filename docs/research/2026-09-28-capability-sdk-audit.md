# SysInfo 调研：原生检测能力边界 + macOS 27 SDK 变动

> **定位**：SysInfo 是从零设计的新 app，不是对 Stats 的移植或 macOS 27 适配。Stats 只作为 popover、菜单栏 widget、桌面小组件的**样式参考**（见 §2）。文中提到 Stats 代码的地方，只用来说明"某种常见做法在 M5 + 27 上是否仍然成立"，不是移植清单。**实现前请先看文末的「后续决策注记」：部分结论已被决策档取代。**
>
> 日期：2026-09-28 · 机器：Mac mini Mac17,16 / M5 Pro（6 Super + 12 Performance）/ 64 GB / macOS 27.0 (26A428) · Xcode 27.0 (27A266a) / Swift 6.4
> 方法：7 个硬件域各由一个 agent 读 Stats 实现 + 在本机编译运行只读探针，再由独立 skeptic 复跑/反驳；4 条 SDK 线（SwiftUI、AppKit、其他框架、WWDC26/发布说明）各由一个 agent 扫描 + 一个 verifier 逐条对 SDK/来源复核（与 CLT 自带的 MacOSX26.5.sdk 做了真 diff）；最后 completeness critic 补缺。
> 约束：全程无 sudo、无 SMC 写、无设置改动；签名均为 ad-hoc；沙盒均**未测**（默认按非沙盒 app 设计，同 Stats）。

图例：✅ 本机实测可用 · ⚠️ 可用但有限制/粗粒度/仅部分对象 · ❌ 本机实测不可用 · ➖ 本机无硬件 · ❔ 未测

---

## 0. 结论速览

### 检测面（硬件/内核）

1. **macOS 27 SDK 对检测面是零 API 变动**：IOKit、CoreHID、SystemConfiguration、CoreWLAN、IOBluetooth、CoreBluetooth、DiskArbitration、ServiceManagement、IOSurface 与 26.5 SDK 规范化 diff 为零。变化全部来自**运行时行为与隐私**，以及 Mach/BSD 头文件里几个新结构（见下）。
2. **IOReport "Energy Model"（PMGR 驱动的 358 个通道）不再实时**：CPU/ANE/DRAM/GPU0 等 mJ 计数器按**固定 1800 s 周期**批量发布（本次开机对齐 xx:08:29 / xx:38:29，与 root 的 powerlog/PerfPowerServices 刷新时间吻合），批与批之间不动。每批数据完整，可当 **30 分钟平均值**，但不能做实时功耗。4 个 probe + 3 个 skeptic 独立复现；root 能否看到更新鲜的值**未测**。这是此前社区 Apple 芯片监控工具测分部件功耗的主流做法，在 M5/27 上会得到 0 W 再加尖峰的结果（Stats 社区 issue #3621/#3626「CPU 功耗一直 0W」即此现象）。**实时替代已全部找到（经 3 个完整 30 min 窗口校准）**：CPU = SMC `RP00+RP01+RP02+RP04`（可按 Super 簇与两个 Performance 簇拆分，30 min 积分为 PMGR 的 0.955 倍）；GPU = AGX `GPU Energy`（与 GPU0 相差 0.01%）；DRAM = SMC `PZD1`（与 DRAM0 完全相等）；SoC 模型总功耗 = SMC `PZC0`（PMGR SoC 合计的 0.995–0.997 倍）；SoC 实测总功耗 = SMC `PHPC`；整机 DC = SMC `PDTR`；墙插 = `PowerTelemetryData`。**只有 ANE 和媒体引擎没有实时来源**（只能显示「最近 30 分钟」）。
3. **跨用户进程可见性：无需 root 即可全量归因**。libproc（`proc_pid_rusage`/`PROC_PIDTASKINFO`）对 328/874 个 root/其他 uid 进程返回 EPERM；但私有的 resource coalition 接口（`proc_listcoalitions` + 27 新增的 `coalition_info_pid_list` + `coalition_info_resource_usage`）对**所有** 771 个 coalition（含 root）可读，一次返回 50 个 u64 槽位：CPU 时间、CPU 能耗（nJ）、GPU 时间与能耗、ANE 时间与能耗、磁盘读写字节、footprint、空闲/中断唤醒、pageins。CPU% 与 `top` 相比平均误差 0.004 个百分点（最大 0.3）；外部进程中 254/329 独占一个 coalition，可精确到单进程，其余 73 个只能按组显示（如 coreaudiod + 5 个 helper）。全量扫描每 tick 约 2.8 ms CPU，是一次 `top -l 1` 的 1/57。Activity Monitor 的后端 sysmond 需要 Apple 私有 entitlement，走不通。**结论：root helper 只剩写 SMC（风扇控制）这一个用途。**
4. **M5 Pro 拓扑**：无 E 核。perflevel0 = "Super"（cpu12–17，IORegistry cluster-type `P`，IOReport 名 `PCPU*`/`PACC_*`，最高 4608 MHz），perflevel1 = "Performance"（cpu0–11，两个 6 核簇，cluster-type `M`，`MCPU0*/MCPU1*`，最高 4380 MHz）。**编号最快的核排最后**。M6 将出现 super/performance/efficiency 三档 → 拓扑必须完全动态发现。
5. **GPU 利用率的老来源失效**：`PerformanceStatistics["Device Utilization %"]` 表现为全局共享的「距上次读取」值——**多个读取者（Stats、活动监视器、我们）会互相污染**，且随提交模式乱跳。改用 IOReport `GPU Stats/GPUPH` 非 OFF 驻留作主指标；`AppUsage.accumulatedGPUTime` 只在命令缓冲完成时入账，适合按进程归因（多秒窗口），不适合 1 Hz 主指标。注意 GPUPH 表示「GPU 上电且在跑」，不是算力占用率（单线程组 kernel 也读 100%，但只耗 2.4 W）→ 旁边配 GPU 功耗。
6. **网络计数器截断**：对 ad-hoc 签名进程，`NET_RT_IFLIST2`（名义上的"64 位"路径，也是常见做法）和 `getifaddrs` 都返回 `floor((真值 mod 2^32)/1024)*1024`；Apple 签名进程拿到完整值。`sysctl net.link.generic.ifdata.<idx>.general`（IFMIB）无特权即可拿精确 64 位值。**Developer ID 签名下是否截断未测**（你有 Developer ID，值得一测）。
7. **host_statistics 全局节流**（CPU 负载与 VM 统计都受影响）：非平台二进制共享**全系统**每 flavor 每秒 2–10 次的新鲜配额，超额得到无标记的缓存数据；任何同时运行的第三方监控 app（包括开发期间开着的 Stats）都会和我们抢这份配额。→ 页面计数改读 `vm.page_*` sysctl；CPU tick 若返回与上次逐字节相同的结果则视为陈旧并跳过。
8. **Wi-Fi SSID/BSSID 需要定位授权**（所有非定位通道都被脱敏）；CoreWLAN 在 27 上高频轮询会引发 airportd XPC 洪泛/Wi-Fi 卡顿（社区 #3629/#3644）。
9. **SMC 无 root 可读全部 2455 个 key**（全部 little-endian `flt`），温度/电压/电流/功率/风扇齐全；SMC 还有一组 M5 的逐域电源轨键（`RP00–RP0C`）以及实时镜像 PMGR 模型的 `PZC0`/`PZD1`。**HID 温度在 M5 上大幅缩水**（没有 pACC/eACC/GPU/SOC MTR 传感器，只剩 PMU tdie/tdev 和 NAND，信息 SMC 全都有），HID 电流/电压是编码未知的真实测量值。风扇写入需 root helper（未测）。
10. **蓝牙**：`IOBluetoothDevice.pairedDevices()` 现在走 CoreBluetooth 协调器，受蓝牙 TCC 约束（无 usage string 直接 abort）；`/Library/Preferences/com.apple.Bluetooth` 里的 DeviceCache 已不存在。AirPods 左/右/盒电量可经私有 `IOPSCopyPowerSourcesByType` **免权限**读取。

### UI / SDK

1. **Liquid Glass 在 27 没有新 API**，只是视觉重调（更强漫射、暗边、更亮高光）+ 系统级「超清 ↔ 全着色」滑块（无公开读取 API；私有全局默认值 `NSGlassTintAmount` 可读）+ **移除"用旧设计"逃生口**。唯一新 API：AppKit `NSGlassEffectView.effectIsInteractive`；SwiftUI `Glass.interactive()` 在 Mac 上开始响应鼠标点击。
2. **菜单栏是 27 对菜单栏常驻监控类 app 最大的变化**：整条菜单栏改由 `MenuBarAgent` 渲染为**单一窗口**（没有逐 item 的 WindowServer 窗口）；空间不足时出现系统**溢出指示器**，而被挤进溢出区的 item 收不到任何公开信号（`isVisible`、`occlusionState` 都不变，还会继续绘制）；菜单栏实际高 30 pt 而 `NSStatusBar.thickness` 仍报 22。实测同宽内容 1 Hz 更新几乎零成本，改宽代价高（§3.1）。链接 27 SDK 时 `NSPopover` 默认就是 Liquid Glass。
3. **新 API `NSStatusItem.expandedInterfaceDelegate` / `expandedInterfaceSession`**（27.0）：点击弹出自定义面板的官方通道，接入菜单栏键盘导航与跟踪。`NSStatusItem.view/target/action` **取消弃用**，自定义绘制 view 重新成为正式路径。
4. **27 已知回归**：status item `occlusionState` 不再反映菜单栏隐藏、按钮高亮无法编程设置（FB23330269/FB23349447）；无 Dock 图标的 accessory app 从非激活状态弹出的窗口会闪退（Stats #3587）→ 用 non-activating `NSPanel` + expanded-interface 回调驱动。
5. **菜单图片默认隐藏**（链接 27 SDK 时，符号与非符号图片都隐藏）→ `NSMenuItem.preferredImageVisibility` / `.labelStyle(.titleAndIcon)`。
6. **同心圆角**：`NSViewCornerConfiguration`/`.containerConcentric`（AppKit 27）、`GeometryProxy.concentricCornerRadii`（SwiftUI 27）。**分段控件 tab 角色**：`NSSegmentedControl.role = .tabs` / `.pickerStyle(.tabs)`。
7. **数据流**：`@State` 变成宏（初值只求值一次）；`withContinuousObservation`（27）可驱动非 SwiftUI 渲染；AppKit 在 `draw(_:)`/`layout()` 中自动跟踪 `@Observable`（26）。`EnvironmentValues.systemPrefersReducedResourceUsage`（27）是给监控类 app 降频的信号（语义未测）。
8. **小组件**：放置后实测 30–45 分钟才重载一次，不能当实时监控；27 新增 `systemExtraLargePortrait`；扩展**必须沙盒**（实测 pkd 会拒绝非沙盒扩展）→ 数据需经 Team ID 前缀的 App Group（Developer ID 签名即可，不需要描述文件）。Mac app 不能创建 Live Activity。Controls（Control Center/菜单栏控件）自 26 可用。
9. **工具链**：27 仅 Apple 芯片，`MACOSX_DEPLOYMENT_TARGET >= 27` 时默认只构建 arm64；ld64 已移除；`libIOReport.tbd`、`libSMC.tbd` 及 PrivateFrameworks tbd 桩仍在 SDK 中，新链接器可链。新工程模板默认：Swift 5 模式、Approachable Concurrency、默认 MainActor 隔离、**App Sandbox 开启**（监控 app 必须关掉）。
10. **隐私/系统**：禁止直接读 TCC.db（有 `tccutil list`）；launchd 拒绝带 quarantine 属性的 plist；SIP/XProtect 默认拒绝访问他人 app 容器；SMJobBless 早已弃用 → `SMAppService`。

---

## 1. 能力矩阵

### 1.1 CPU / 热

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| 总占用 user/sys/idle | `host_statistics(HOST_CPU_LOAD_INFO)` 差分 | Mach | 无 | ⚠️ | 数值正确，但受全局节流：其他第三方监控在跑时可能拿到陈旧值（§0-7） |
| 每核占用 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | Mach | 无 | ✅ | 索引 = cpuN = IOReport 通道顺序；0–11 为 Performance(M)，12–17 为 Super |
| 拓扑 / 核类型 | `hw.nperflevels`、`hw.perflevelN.{name,logicalcpu,cpusperl2,l2cachesize}` + IORegistry `AppleARMPE` 子节点 `cluster-type`/`cluster-id` | 公开 + 未文档键 | 无 | ✅ | perflevel0 永远是最快档但核号在最后；按 cluster-id 分组（本机 3 簇）；不要依赖字母 E/M/P 的代际语义 |
| DVFS 频率表 | IORegistry `pmgr` 的 `voltage-states*-sram` | 未文档键 | 无 | ✅ | Super=`voltage-states5-sram`（20 档 1308–4608 MHz），M=`22/23-sram`（15 档 1344–4380）；CPU 表单位 kHz；键号随芯片变 → 用 IOReport 状态数匹配 |
| 每簇**实际**频率 | IOReport `CPU Complex Performance States` 的 **M5 新通道 `PCPM` / `MCPM0` / `MCPM1`** 驻留 × DVFS 表 | 私有 (`-lIOReport`) | 无 | ✅ | 与真实时钟误差约 1%。多核负载下 Super 实际 4191–4270 MHz（单核 4541–4580） |
| 每核**请求**频率 | IOReport `CPU Core Performance States`（`PCPU0-5`、`MCPU00-15`）及旧簇通道 `PCPU/MCPU0/MCPU1` | 私有 | 无 | ⚠️ | 反映的是请求的 DVFS 档而非实际时钟，多核时 Super 高估约 8%；PMGR 类订阅每次采样约 5 ms CPU（GPU Stats 仅 0.3 ms）→ 合并 PMGR 组到一个订阅 |
| 每核活跃驻留 | IOReport 同组非 IDLE/DOWN 驻留 | 私有 | 无 | ✅ | 与 tick 统计吻合，略高（计入非门控时间） |
| 负载均值 / 开机时间 | `getloadavg()`、`KERN_BOOTTIME` | 公开 | 无 | ✅ | 不要用 `HOST_LOAD_INFO.avenrun`（算法不同） |
| 中断率 | IOReport `Interrupt Statistics (by index)` | 私有 | 无 | ✅ | 约 333 次/s，可按设备分解 |
| 上下文切换 | 各进程 `pti_csw` 求和 | libproc | 同 uid | ⚠️ | 无系统级计数器 |
| 任务/线程数 | `processor_set_statistics(PROCESSOR_SET_LOAD_INFO)` | Mach | 无 | ✅ | |
| CPU 温度 | SMC `Tp0*`（Super 簇 18 个）+ `Tm0*`（M 簇 0）+ `Tm1*`/`Tm2*`（M 簇 1） | SMC | 无 | ✅ | 只读 Tp** 会漏掉 12 个 M 核；`Tm0y` = `Tm2T` = `Tp0a` 是别名，求平均时去重 |
| SoC 热点 | SMC `TVD0`/`TVDC`/`TVDP`/`TCMb`；组最大值 `TPDX`/`TRDX`/`TTDX` | SMC | 无 | ✅ | 最高的温度读数，适合当「最热」指标 |
| 热压力 | `ProcessInfo.thermalState`（4 档 nominal/fair/serious/critical）+ notify `com.apple.system.thermalpressurelevel`（`OSThermalPressureLevel`，另一套枚举，不可互相映射） | 公开 | 无 | ✅ | 只观察到 nominal；旧 IOPM 热 API 返回 NotFound（= 未发布，非不支持） |
| CPU 功耗（实时） | ~~IOReport Energy Model~~ | 私有 | 无 | ❌ | 30 min 批量发布，见 §0-2 |
| CPU 功耗（30 min 均值） | IOReport Energy Model `CPU Energy`/`PCPU`/`MCPU0/1` 批次差分 | 私有 | 无 | ✅ | 批次时间 = 开机 + 193 s 对 1800 取模 → 按变化检测，不要写死 xx:08:29；可用来校准实时 RP* 键 |
| CPU 功耗（实时） | SMC `RP00`（Super 核）+ `RP01`（Super SRAM）+ `RP02`、`RP04`（两个 Performance 簇） | SMC | 无 | ✅ | 1 Hz、1/256 W 量化；30 min 平均比 PMGR 低 4.5%（可以用最近一批 PMGR 数据得到系数 k≈1.047 校准）；Super 重载时比模型低约 20%；显示时做 τ≈2–3 s 的 EMA |
| ~~CPU 功耗 = PHPC − GPU~~ | — | — | — | ❌ | PHPC 还包含 DRAM、内存控制器、fabric、ANE、AVE 和约 2 W 的空闲底；与 PMGR CPU 相比是 1.4–2.0 倍 |
| ~~CPU 簇功耗（PMP0 直方图）~~ | IOReport `PMP0/Energy`（MACC0/MACC1/PACC + SRAM） | 私有 | 无 | ⚠️ | 2 W 分桶，30 min 积分是 PMGR 的 1.75 倍 → 已被 SMC `RP*` 取代 |
| 簇电压×温度 | IOReport `PMP0/Volt-Temp HM` | 私有 | 无 | ✅ | 25 mV × 10 ℃ 分桶 |
| 每进程 CPU% | libproc 差分（`proc_pid_rusage` v6） | libproc | 同 uid | ⚠️ | 546/874；时间单位是 mach tick（×125/3 ns）不是 ns |
| 每进程 CPU%（全体） | coalition 资源用量 / `top -l 2 -s 1 -stats pid,command,cpu,csw`（setuid，真区间值）/ `/bin/ps`（衰减均值） | 私有 / CLI | 无 | ✅ | CLI 都要 spawn；top 至少 1 s 墙钟，ps 约 92 ms |
| 每进程 Super/Performance 占比、能耗 | `rusage_info_v6` `ri_*_ptime`、`ri_penergy_nj`、`ri_energy_nj` | libproc | 同 uid | ✅ | "p" 字段 = perflevel0 = Super 核 |
| 新：每核计数器 `PROCESSOR_CPU_COUNTERS_INFO` | `host_processor_info(3)` | 27 SDK 新增 | 私有 entitlement | ❌ | `KERN_NO_ACCESS`；需 `com.apple.private.kernel.cpu-counters-info` |
| 新：`HOST_CPU_COUNTERS_INFO` | `host_statistics64(8)` | 27 SDK 新增 | ? | ❌ | `KERN_INVALID_ARGUMENT`（非平台二进制） |


### 1.2 GPU / ANE / 媒体引擎

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| GPU 利用率 | IOReport `GPU Stats/GPU Performance States` 通道 `GPUPH`：1 − OFF/total | 私有 | 无 | ✅ | 25/60/100% 负载 → 26/60/100%；含义是「上电且忙」而不是占用率 → 配合 GPU 功耗展示；采样仅约 0.3 ms |
| GPU 利用率（按进程合计） | `AGXDeviceUserClient` 子节点 `AppUsage[].accumulatedGPUTime` 差分求和 | 未文档键 | 无 | ⚠️ | 命令缓冲完成时才入账，长 buffer 下每秒值在 6% 与 136% 之间跳；按 client registry ID 分别求差、平滑数秒 |
| ~~Device Utilization % / Renderer / Tiler~~ | `IOAccelerator.PerformanceStatistics` | 未文档键 | 无 | ❌ | 多读者互相污染 + 随提交模式乱跳；Renderer 也不区分渲染/计算 |
| GPU 频率 | GPUPH 状态 Pk × `pmgr voltage-states9` | 私有 + 未文档键 | 无 | ✅ | 13 档 338–1620 MHz；**GPU 表单位是 Hz**（CPU 表是 kHz） |
| GPU 功耗 | Energy Model 中 AGX 的 `GPU Energy`（nJ） | 私有 | 无 | ✅ | 唯一仍实时的 Energy Model 通道；0.01–35 W |
| GPU 温度 | SMC `Tg*`（42 个，分属两个 mGPU 分区：Tg08..Tg1o / Tg1x..Tg43） | SMC | 无 | ✅ | 空闲 52 ℃ → 负载 73 ℃；空闲时各分区读数是同一个填充值，最小/最大/离散度无意义 |
| GPU 内存 | `PerformanceStatistics` `In use/Alloc system memory` | 未文档键 | 无 | ✅ | |
| 每应用 GPU 时间/能耗 | coalition slot 8（gpu_time ns，与 Metal 自报的命令缓冲执行时间吻合）/ slot 41（gpu_energy nJ） | 私有 | 无 | ✅ | 首选；按 coalition 粒度 |
| 每进程 GPU（按 pid） | `AppUsage` + `IOUserClientCreator`（"pid N, name"） | 未文档键 | 无 | ⚠️ | 能精确到 pid，但对短小或间歇提交会高估（统计的是上电时间） |
| GPU 节流状态 | IOReport `GPU_CLTM`、`PWRCTRL` | 私有 | 无 | ⚠️ | 语义按名称推断，未触发过节流 |
| GPU 标识/核数 | `MTLDevice` + IORegistry `gpu-core-count`、`model` | 公开 + 未文档键 | 无 | ✅ | 无需 spawn system_profiler；M5 Pro GPU 为 2×10 核 mGPU |
| ANE 功耗/利用率 | Energy Model `ANE0` | 私有 | 无 | ❌ | 只有 30 min 均值 |
| ANE 是否活跃 | IORegistry `H11ANEIn` `IOPowerManagement.CurrentPowerState` | 未文档键 | 无 | ✅ | 仅开/关，关断滞后约 5.5 s；M5 ANE 在 Exclave 后面，中断统计订阅会静默缺失 ane0 |
| ANE 活动强度 | IOReport `PMP0` `AF BW`/`SOC-NI Util BW` ANE 通道 | 私有 | 无 | ⚠️ | 相对量 |
| 每进程 ANE 内存 | `ri_neural_footprint` | libproc | 同 uid | ✅ | 27 起 ANE 内存计入 app 进程 |
| 每应用 ANE 时间/能耗 | coalition slot 38（ane_mach_time）/ slot 39（ane_energy nJ） | 私有 | 无 | ✅ | M5 上**唯一**的每应用 ANE 数据源；饱和时约 74% 忙、3.6 W；单位由饱和与能量一致性推定 |
| 媒体引擎（编码/解码/ProRes） | IOReport 中断统计 `ave0`/`avd0`/`apr0` 速率 + `PMP0 SOC Floor/SOC-NI` | 私有 | 无 | ✅ | IRQ ≈ 2×帧率（编码） |
| 每客户端 DRAM 带宽 | IOReport `AMC Stats` | 私有 | ? | ❌ | 订阅返回 NULL |
| 帧率 FPS | IOReport `DCPEXT*` `swap` | 私有 | 无 | ➖ | 本机只有虚拟显示器，未测 |
| 显示器 | `CGGetActiveDisplayList`、`CGDisplayMode.refreshRate` | 公开 | 无 | ✅ | |


### 1.3 内存

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| 物理/可用内存 | `hw.memsize`、`hw.memsize_usable`、`boot_stolen_count` | 公开 | 无 | ✅ | 64 GiB vs 63.24 GiB（0.76 GiB 引导保留） |
| 页面分类 | `host_statistics64(HOST_VM_INFO64)` **rev6（104 ints）** | Mach | 无 | ✅ | 27 SDK 新增 internal/external 活跃/非活跃拆分、swap_count、executable_count 等 |
| 页面分类（无节流） | `vm.page_free_count`、`page_wired_count`、`page_pageable_internal/external_count`… | sysctl | 无 | ✅ | 规避全局节流（§0-7） |
| 已用/App/联动/压缩/缓存 | Activity Monitor 公式（app = internal − purgeable） | — | — | ✅ | 与独立 sysctl 计算吻合（26.96 vs 26.97 GiB） |
| 内存压力 | `kern.memorystatus_vm_pressure_level`（1/2/4）、`kern.memorystatus_level`（%）、`DispatchSource.makeMemoryPressureSource` | sysctl / 公开 | 无 | ✅ | 只见过 normal |
| Swap / 换页速率 | `vm.swapusage`、`vm_statistics64` 累计计数差分 | sysctl | 无 | ✅ | 本机 swap = 0 |
| 压缩比 | `total_uncompressed_pages_in_compressor / compressor_page_count` | Mach | 无 | ✅ | 约 2.7:1 |
| MTE 标签存储（M5） | `vm_statistics64` tag 字段、`vm.mte.*` | 公开 | 无 | ✅ | 2 GiB 标签区大部分复用为普通内存 |
| DRAM 带宽 | IOReport `PMP0/DCS BW` AMCC RD/WR | 私有 | 无 | ✅ | 16 GB/s 分桶；只宜作相对量 |
| ECC 纠错计数 | `vm.vm_ecc_corrected_count` | sysctl | 无 | ⚠️ | 值不变，未确认是实时计数器 |
| 每进程 footprint（同 uid） | `proc_pid_rusage.ri_phys_footprint` | libproc | 同 uid | ✅ | = Activity Monitor "内存"列；全扫 874 进程约 12.7 ms |
| 每进程 footprint（其他 uid/root） | coalition 资源用量 slot 40（见 §1.8） | 私有 | 无 | ✅ | 254/329 精确到单进程，73 个只有组合计；槽位下标为实测所得，可能随系统版本变化 |
| 同上（CLI 回退） | `/usr/bin/top -l 1 -o mem`（setuid） | CLI | 无 | ✅ | 每次约 150 ms CPU |
| 进程名/路径（全体） | `PROC_PIDT_SHORTBSDINFO`、`proc_pidpath` | libproc | 无 | ✅ | 别用 `proc_name()`（对外部进程静默返回空） |
| 结束进程 | `kill()` | 公开 | 同 uid | ⚠️ | root/其他 uid 进程需 helper |
| jetsam 信息 | `memorystatus_control` | 私有 | root/entitlement | ❌ | |

### 1.4 磁盘 / 存储

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| 卷列表 | `getmntinfo` / `FileManager.mountedVolumeURLs` | 公开 | 无 | ✅ | `mountedVolumeURLs` 不返回 `/System/Volumes/Data` |
| 容量 / 可清除空间 | `statfs` + `volumeAvailableCapacityForImportantUsage` 或 `CSDiskSpaceGetRecoveryEstimate` | 公开 | 无 | ✅ | 后两者 15–60 ms/次 → 缓存 ≥60 s |
| System / Data 分拆 | `getattrlist(ATTR_VOL_SPACEUSED)` + IORegistry `AppleAPFSVolume.Role` | 公开 + 未文档键 | 无 | ✅ | 容器内所有卷共享同一个"可用"值，已用量要逐卷读 |
| 挂载/卸载/弹出事件 | DiskArbitration 回调 / `NSWorkspace` 通知 | 公开 | 无 | ✅ | 需去抖、过滤 cryptex/模拟器镜像与 `MNT_DONTBROWSE` |
| 吞吐 / IOPS | `IOBlockStorageDriver.Statistics` | 公开 | 无 | ✅ | 平均延迟 = ΔTotal Time/Δops；**%busy 不可得**（Total Time 会重叠计数） |
| 每 APFS 卷 IO | `AppleAPFSVolume.Statistics`（"Bytes written by user"…） | 未文档键 | 无 | ✅ | |
| 每进程 IO（同 uid） | `ri_diskio_bytesread/written` | libproc | 同 uid | ✅ | |
| 每进程 IO（全体） | coalition 资源用量 index 6/7 | 私有 | 无 | ✅ | 唯一无 root 看到 mds/logd/kernel_task 写入的办法 |
| NVMe SMART（内置 + 外置） | `IOKit/storage/nvme/NVMeSMARTLibExternal.h`（公开头，需 bridging header） | 公开 | 无 | ✅ | 内置 APPLE SSD AP1024Z + 5 块雷电 5 外置 Intel NVMe 都可读 |
| Apple SSD 通电时间 | SMART POH | 公开 | 无 | ⚠️ | 严重偏低（控制器 ACTIVE 46 h 而 POH=14）→ 内置盘隐藏此项 |
| 磁盘温度 | SMART composite / HID `NAND CH0 temp` | 公开 / 私有 | 无 | ✅ | SMC `TN00-TN03` 跟随 HID NAND；`TH0*` 与之差 1–2 ℃（两个 skeptic 符号相反，未定论）→ 以 SMART 为准 |
| SSD 节流 | IOReport `NVMe` 组 `BW Scale Factor`（绝对值，<100 即节流） | 私有 | 无 | ⚠️ | |
| ATA SMART | — | — | — | ➖ | 无 SATA/USB 盘；`SMARTEnableDisableOperations` 会写设备状态，只读设计应避免 |

### 1.5 网络

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| 接口字节计数 | `sysctl net.link.generic.ifdata.<idx>.general`（IFMIB） | sysctl | 无 | ✅ | 精确 64 位 |
| ~~接口字节（常见做法）~~ | `NET_RT_IFLIST2` / `getifaddrs` | sysctl | — | ❌ | ad-hoc 签名下 32 位 + 1 KiB 量化，10 GbE 满速约 3.4 s 回绕一次 |
| 包 / 错误 / 丢弃 | IFLIST2 `if_data64` / IFMIB | sysctl | 无 | ✅ | vmenet* 的 iqdrops 是垃圾值 |
| 链路速率 | `SIOCGIFLINKPARAMS`（27 上命令字 0xc1006992）或 IOKit `IOLinkSpeed`（需 `IOLinkStatus` 活跃位） | ioctl / IOKit | 无 | ✅ | `ifi_baudrate` 在 4.29 Gbps 饱和，10 GbE 会显示 4295 Mbps |
| 链路质量 | `SIOCGIFLINKQUALITYMETRIC` / `NWPath.linkQuality` | ioctl / 公开 | 无 | ✅ | |
| 主接口 / 本地 IP / DNS | `SCDynamicStore State:/Network/Global/*`、`NWPathMonitor` | 公开 | 无 | ✅ | DNS 用 Global 键才能反映 VPN/NE 解析器 |
| 每进程流量（全体） | spawn `/usr/bin/nettop` | CLI | 无 | ✅ | 约 20 ms；流关闭后进程总量会下降 → 要按流 ID 累计 |
| 每进程流量（进程内） | 私有 `NetworkStatistics.framework` `NStatManager` | 私有 | 同 uid | ⚠️ | 看不到 root/_mdnsresponder 等 |
| Wi-Fi RSSI/噪声/速率/信道/PHY | CoreWLAN `CWInterface` | 公开 | 无 | ✅ | 本机 Wi-Fi 7（802.11be），ch149/80 MHz；SDK 仍无 320 MHz 枚举 |
| Wi-Fi SSID/BSSID | CoreWLAN + CoreLocation 授权 | 公开 | TCC 定位 | ❌ | 未授权时所有通道脱敏；授权后行为未测 |
| Wi-Fi 事件 | `CWEventDelegate` | 公开 | 无 | ⚠️ | 注册成功，事件投递未测 |
| ICMP 延迟 | `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` | 公开 | 无 | ✅ | v6 需按 type/id 过滤 |
| VPN 检测 | 主接口为 utun/ipsec/ppp + 可路由地址 | 公开 | 无 | ⚠️ | 本机 8 个空闲系统 utun，不能仅凭存在判断 |
| 公网 IP | 外部服务（URLSession） | 外部 | 无 | ❔ | 未执行 |

### 1.6 SMC 传感器 / 风扇 / 整机功耗

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| SMC 枚举 | `AppleSMC` user client selector 2（cmd 8/9/5） | SMC | 无 | ✅ | 2455 键，1.28 s 全枚举 → 启动时一次并缓存 key-info；107 个键不可读；**检查 SMC result 字节**；字节序看属性位 0x04（有 = 小端） |
| 温度 | SMC `T*`（243 个） | SMC | 无 | ✅ | 全是 LE `flt`；少数 `ioft`（16.16 定点）/`si32`；部分 T* 不是温度（TNSz、TVMD…） |
| 电压 / 电流 | SMC `V*`（41）/ `I*`（50） | SMC | 无 | ✅ | `VD0R×ID0R = PDTR`，误差 0.1% |
| 整机 DC 功率 | SMC `PDTR`（= PD0R = VD0R×ID0R） | SMC | 无 | ✅ | 1 Hz 实时，空闲约 7 W，18 线程 52 W，memcpy 59 W；`PSTR` 就是晚 1 s 的 PDTR，别用；积分与 PowerTelemetryData 累加器相差 0.1% |
| 整机功率 60 s 均值 / 墙插功率估算 | `AppleSmartBattery.PowerTelemetryData`：ΔAccumulatedSystemPowerIn；ΔAccumulatedWallEnergyEstimate × 3.6 | 未文档键 | 无 | ✅ | 每 60 s 发布一次；DC/墙插比 0.86–0.90；累加器跨 app 重启保留，是最好的长期能耗计数器；快照字段 SystemPowerIn 只是某一秒的值，别直接用 |
| CPU 功耗（按簇） | SMC `RP00+RP01`（Super）/ `RP02`、`RP04`（Performance 簇） | SMC | 无 | ✅ | 见 §1.1 |
| GPU 功耗 | AGX `GPU Energy`（nJ，≥10 Hz 更新）；备选 SMC `RP05+RP08` | 私有 / SMC | 无 | ✅ | |
| DRAM 功耗 | SMC `PZD1` | SMC | 无 | ✅ | 与 PMGR DRAM0 完全相等（3 个窗口 1.000/0.999/1.000）；不含内存控制器/PHY |
| 内存子系统 | SMC `RP06/RP07/RP0B/RP0C` | SMC | 无 | ⚠️ | 标签是按负载响应推断的，只宜作相对量 |
| SoC 总功耗（模型） | SMC `PZC0`（= `PZC1`） | SMC | 无 | ✅ | = PMGR 模型的实时版本（0.995–0.997）；比 PHPC 滞后约 1 s |
| SoC 总功耗（实测） | SMC `PHPC`（= `PPSM`） | SMC | 无 | ✅ | 包括 CPU/GPU/ANE/AVE/DRAM/内存/fabric；空闲约 1.8–2.4 W，比模型高约 1.5 W |
| ANE / 媒体引擎功耗 | PMGR `ANE0`/`AVE0` 30 min 批次 | 私有 | 无 | ⚠️ | 没有实时键；ANE 饱和时约 3.96 W，4K HEVC 编码约 0.39 W |
| ~~`IOReportCreateSnapshotDeltas`~~（27 新导出） | — | 私有 | — | ❌ | 全系统只有 2 个共享槽位，PMGR 仍然冻结，不要用 |
| HID 温度 | 私有 `IOHIDEventSystemClient`（0xff00/5） | 私有 | 无 | ⚠️ | 只剩 PMU tdie1–14/tdev1–8/tcal（每个注册 3 次）+ NAND |
| HID 电流/电压 | 同上（0xff08） | 私有 | 无 | ⚠️ | 随负载按电源轨变化，是真实测量，但编码未知；直接用 SMC V*/I* |
| CoreHID | `HIDDeviceManager` | 公开 | 无 | ❌ | 只能看到真实 HID 设备（UPS、耳机…），碰不到传感器服务 |
| 风扇读数 | SMC `FNum`、`F0Ac/F0Mn/F0Mx/F0Tg/F0md` | SMC | 无 | ✅ | 1 个风扇，1000–4900 RPM；模式键是小写 `F0md`，无 `Ftst` |
| 风扇控制 | SMC 写 `F0md=1` + `F0Tg` | SMC | **root helper** | ❔ | 需 `SMAppService.daemon` + 用户在「登录项」批准 + 真实签名；helper 的 XPC 必须用 `setCodeSigningRequirement` 锁定 Team ID（比较证书数组的做法在 ad-hoc 下等于不校验） |


### 1.7 电源 / UPS / 蓝牙配件

| 指标 | 推荐来源 | 类别 | 权限 | 本机 | 备注 |
|---|---|---|---|---|---|
| 电源列表（内置电池 / UPS） | `IOPSCopyPowerSourcesInfo` | 公开 | 无 | ✅ | 本机只有 UPS：100%、剩余 22–28 min、输入电压 230000 mV |
| UPS 扩展遥测 | **公开 CoreHID**（`HIDDeviceClient` 读元素，仅 GET_REPORT）或 IOHIDManager，电源设备页 0x84/0x85 | 公开 | 无 | ✅ | 负载 %（覆盖 UPS 上所有设备）、电池电压、切换阈值、额定 600 W；按标准 HID 单位换算 |
| 内置电池详情 | `AppleSmartBattery`（循环次数、健康度、温度…） | 未文档键 | 无 | ➖ | 桌面机也有 stub 服务 → 必须判断 `BatteryInstalled` |
| 电源切换通知 | `IOPSNotificationCreateRunLoopSource` | 公开 | 无 | ✅ | 有 UPS 时每 1–10 s 触发一次 → 必须去抖 |
| AirPods 左/右/盒电量 | 私有 `IOPSCopyPowerSourcesByType(4)` + `IOPSAccNotificationCreateRunLoopSource` | 私有 | 无 | ✅ | 放在盒里未连接也能读；按 Group+Part Identifier 做键（ID 会变） |
| 蓝牙设备 + 电量（CLI） | `system_profiler SPBluetoothDataType -json` | CLI | 无 | ✅ | 40–130 ms |
| 蓝牙设备（API） | `IOBluetoothDevice.pairedDevices()` / CoreBluetooth | 公开 | TCC 蓝牙 | ❌ | 无授权时 abort；授权后未测 |
| 电源断言（谁阻止睡眠） | `IOPMCopyAssertionsByProcess` + `IOPMrootDomain.DriverPMAssertionsDetailed`（Level==255） | 公开 + 未文档键 | 无 | ✅ | |
| 低/高功耗模式 | `ProcessInfo.isLowPowerModeEnabled`；高功耗只能经私有 `IOPMCopyActivePMPreferences` | 公开 / 私有 | 无 | ✅ | |
| 每进程能耗 | `ri_energy_nj`（同 uid）/ coalition（全体）/ `top -o power`（无单位分数，1.2 s） | 混合 | 无 | ⚠️ | |

### 1.8 每应用资源归因（resource coalition，私有，无需 root）

| 槽位 | 含义 | 单位 | 验证 |
|---|---|---|---|
| 24–30 求和（eqos） | CPU 时间 | mach tick（×125/3 ns） | 522 个单成员 coalition 与 `top TIME` 完全一致；slot 3 在长寿命进程上偏低 3–13%，不要用 |
| 11 | CPU 能耗 | nJ | 与本 coalition 成员的 `ri_energy_nj` 之和逐位相等 |
| 8 / 41 | GPU 时间 / GPU 能耗 | ns / nJ | 与 Metal 命令缓冲时间吻合 |
| 38 / 39 | ANE 时间 / ANE 能耗 | mach tick / nJ | 饱和测试推定 |
| 6 / 7 | 磁盘读 / 写字节 | B | 64 MiB 读写精确命中 |
| 12–15、33 | 逻辑写、文件系统元数据写 | B | |
| 40 | phys_footprint | B | 与 `top MEM` 一致（253/253） |
| 4 / 5 | 中断唤醒 / 空闲（package）唤醒 | 次 | slot 5 与 `top IDLEW` 522/522 相等 |
| 49 | pageins | 页 | 与 `ri_pageins` 相等（27 新增槽位；45–48 推定为 pages_grabbed 系列） |

- 枚举：`proc_listcoalitions(2, 0)` → `{cid, type, tasks}`；成员：`coalition_info_pid_list(cid, …)`（27 新增 flavor 5，公开 xnu 里没有）。
- 缓冲区大小 400 字节（50 × u64）；公开 xnu-12377（26.x）只有 45 个槽位 / 360 字节。
- coalition 在最后一个成员退出后仍可读 → 用 `tasks == 0` 过滤掉。
- 从 LaunchServices 启动的 app，其 coalition 包含 app 本身及其 XPC 服务，这正好就是「按应用」的归因粒度。
- 风险：接口未文档化，槽位含义靠实测，系统更新后可能变化 → 启动时自检（例如本进程 slot 11 应等于 `ri_energy_nj`），失败则回退到同 uid libproc + setuid `top`。

---

## 2. UI 样式参考：Stats 的菜单栏 widget / popover / 桌面小组件

> 这一节只借鉴 Stats 的**样式与交互**。右列是在 macOS 27 上用原生方式实现的要点；Stats 自身的实现方式（普通 NSWindow + NSVisualEffectView + 手工定位）不作参考。

### 2.1 菜单栏 widget 形态（Stats 共 15 种）

| 形态 | 样式 | 典型用途 | 27 落地要点 |
|---|---|---|---|
| mini | 大号数值 + 角标小标签（如 "CPU"），可按负载分区着色 / 强调色 / 单色 | CPU%、内存%、单个传感器 | 透明菜单栏下默认用 `labelColor`/模板色，只在超阈值时着色；高度按 `button.bounds`（30 pt）排版 |
| label | 纯文字标签 | 搭配其他形态 | 可以直接用 SF Symbol 代替 |
| line_chart | 迷你折线（历史长度、边框、数值叠加、按值着色、线性/对数/固定刻度） | CPU/GPU/内存历史 | 模板渲染的 CALayer/Canvas；与采样 tick 合并重绘 |
| bar_chart | 竖条：总量 / 每核 / 每簇（按核类型着色）/ 分段（sys+user、App/Wired/Compressed） | CPU 每核、内存构成、风扇% | 核类型颜色按 perflevel 动态分配（Super/Performance/未来的 Efficiency） |
| pie_chart / tachometer | 小饼图 / 仪表盘 | sys/user 占比 | 可以用 SF Symbol 可变值 `.draw` 模式（`gauge.with.needle` 等）做模板化仪表 |
| speed | 上下两行速率 + 箭头/圆点/字符图标；可设"低于阈值不显示" | 网络、磁盘读写 | 等宽数字；单位自动或固定 |
| network_chart | 上下行双向迷你图 | 网络、磁盘 IO | 同 line_chart |
| memory | 两行 used/free | 内存、磁盘容量 | |
| stack（sensors） | 1–2 行排列多个值，可等宽、固定宽度 | 多个温度、蓝牙配件电量、多时区时钟 | 最省菜单栏宽度，适合溢出受限的 27 菜单栏 |
| battery / battery_details | 电池图标（内含百分比/剩余时间/充电状态）/ 文字详情 | 电池、UPS | 桌面机无电池时显示 UPS 或配件 |
| state（dot） | 状态圆点 | 联网状态、内存压力 | |
| text | `$变量` 模板（如 `$mem.used/$mem.total ($pressure.value)`） | 任意组合 | 一个通用 widget 覆盖大量长尾需求，值得保留这个思路 |
| drive_mini | 指定物理盘的温度或寿命 | SMART | |

**布局模式**：① 每个 widget 一个 status item；② 每模块合并为一个 item；③ 所有模块合并为单个 item（按点击的 x 坐标判断落在哪个模块，弹出该模块或"合并详情"）。27 新增的系统溢出指示器会把放不下的 item 收起来，app 收不到信号。**决策 D06**：默认 ①/②（每模块一个 item），并提供 ③ 合并选项。

**27 渲染要点**：`NSStatusItem.view` 已取消弃用，可以放自绘 view 或 `NSHostingView`；AppKit 会在 `draw(_:)` 中自动跟踪 `@Observable`，也可用 `withContinuousObservation` 驱动重绘；菜单栏是透明的，颜色不要按"是否深色模式"写死，要用模板/语义色；通过 `removalAllowed` + KVO `isVisible` 感知用户是否在系统设置里隐藏了 item。

### 2.2 Popover（弹出面板）结构

| Stats 样式 | 27 落地 |
|---|---|
| 顶部栏：左侧「活动监视器」按钮、中间标题、右侧模块设置按钮 | 用玻璃按钮 `.buttonStyle(.glass)`；可点击的玻璃元素设 `effectIsInteractive` / `.interactive()` |
| 主体从上到下：仪表（使用率饼图 / 温度 / 平均频率）→ 历史曲线（1–10 min，线性/对数/固定刻度）→ 明细键值 → Top N 进程（带 app 图标，悬停出现结束按钮） | 卡片放进 `GlassEffectContainer` / `NSGlassEffectContainerView`；**图表与数值层用标准材质或不透明底**，玻璃只用在导航和控件层；卡片圆角 `.containerConcentric` |
| 每核柱状图按核类型着色 | 同上，颜色随 perflevel 动态 |
| 可以把面板拖出来变成独立浮窗（带关闭按钮） | `NSPanel`（`.nonactivatingPanel`）+ `.floating` 层级；拖出后脱离 expanded-interface session |
| 合并详情：所有模块的"portal"小卡片纵向堆叠 | 天然就是一个 GlassEffectContainer 里放多张卡片 |
| 模块间切换 | `.pickerStyle(.tabs)` / `NSSegmentedControl.role = .tabs`（27） |
| 打开/关闭：Stats 手工定位窗口并用 occlusionState 判断 | `expandedInterfaceDelegate` 的 didBegin/didEnd 回调；单个可复用面板切换内容，避免 27 上窗口切换闪烁（Stats #3619） |

### 2.3 桌面小组件（WidgetKit）

- **Stats**：每个模块一个 `systemSmall`（CPU 用 system/user/idle 甜甜圈，GPU、RAM、Disk、Network 类似）+ 一个 `UnitedWidget`（`systemSmall` 汇总）；主 app 把快照写进 App Group，扩展读取后显示。
- **27 落地**：新增 `systemExtraLargePortrait`，可以做整页竖版仪表盘；要能在 clear/tinted 两种渲染下正常显示（`widgetAccentable`、不只靠色相传达温度高低）。
- **实测约束**（gap 验证）：① 扩展**必须沙盒**，pkd 会直接拒绝不带沙盒的扩展（"plug-ins must be sandboxed"）；② 数据经 **Team ID 前缀**的 App Group（如 `<TeamID>.xxx`）传递，Developer ID 签名下无需描述文件、无弹窗；`group.` 前缀的需要描述文件；ad-hoc 签名没有 Team ID，用不了这条路；③ 已放置小组件的实际重载间隔为 31.7–45.5 分钟（系统天气组件，24 h 共 37 次），菜单栏 host 每秒调用 `reloadTimelines` 也只会被计入预算 → 小组件只能放「慢摘要」，或用 timeline 预排多个条目；④ 未验证的自用捷径：`defaults write com.apple.chronod widgetKitDeveloperModeEnabled -bool YES` + 以 get-task-allow 签名的扩展可以免除预算（chronod 里有这个豁免原因）；⑤ Control（控制中心/菜单栏控件）同样运行在沙盒扩展里；27 新增的 `IntentExecutionTargets = .main` 可以让控件的**动作**在非沙盒主进程执行，但 value provider 仍在扩展里。

### 2.4 设置窗口

- **Stats**：侧栏（仪表盘、通用、各模块）+ 每模块分 Module / Widgets / Popup / Notifications 四个标签 + widget 缩略图（由真实 widget view 渲染）拖拽排序 + 实时预览页 + 导出/导入设置。
- **27 落地**：`NavigationSplitView` + 标准工具栏（自动获得 27 的统一外观）；标签用 `.pickerStyle(.tabs)`；排序用 `reorderable()`（27）；Settings 场景可通过 `NSHostingSceneRepresentation` 挂在 AppKit 生命周期上。

### 2.5 数据层：常见做法在 M5/27 上的陷阱（经验记录，非移植清单）

以下都是本次探针实测到的"看起来合理但在这台机器上错"的做法，括号里是 Stats 中的实例，仅作证据：
- 用 Energy Model 差分测 CPU/ANE/DRAM 功耗 → 0 W 加尖峰
- 用 `PerformanceStatistics["Device Utilization %"]` 当 GPU 利用率 → 严重失真
- 用 IFLIST2/getifaddrs 读网络字节 → 32 位回绕 + 1 KiB 量化；负差值被钳为 0 时会丢流量
- 用 `ifi_baudrate` 取链路速率 → 在 4.29 Gbps 饱和
- 把 28 字节的 `sockaddr_in6` 拷进 16 字节的 `sockaddr` → IPv6 地址乱码（Stats `Net/readers.swift:487-501`）
- 按字母 E/M/P 猜核类型、按品牌字符串猜芯片代际 → 碰巧在 M5 Pro 上对，M6（三档）上会错
- CPU 温度只读 Tp** → 漏掉 M 簇
- 以 HID Product 名做字典键 → M5 上每个 PMU 传感器注册 3 次，70 个服务被覆盖成 24 个
- SMC 只解码 `flt`/`sp78`/大端整数 → `ioft`、`si32`、小端键读成 0
- 解析 `top` 的 MEM 列时把二进制单位当十进制 → 低报 4–7%
- 每秒 spawn `ps`/`top`/`nettop`/`system_profiler` → 每次 20–160 ms CPU；`top -o power -l 2` 一次 1.2 s
- 把任何 IOPS 电源都当成"电池" → 桌面机上 UPS 被显示成电池，甚至显示成蓝牙设备
- 原样显示内置 SSD 的通电时间 → Apple 控制器严重低报
- 高频轮询 CoreWLAN → 27 上 airportd XPC 洪泛（社区报告）

---

## 3. macOS 27 SDK / 平台变动（已逐条复核）

### 3.1 菜单栏与 status item（AppKit）

| 项 | 变化 | 对我们的意义 |
|---|---|---|
| `NSStatusItem.expandedInterfaceDelegate` / `expandedInterfaceSession` / `NSStatusItemExpandedInterfaceSession.cancel()` | **27 新增** | 点击弹出面板的官方方式：在 `didBegin` 中显示、`didEnd` 中隐藏，外部点击时调用 `cancel()`；自动获得菜单栏键盘导航与高亮 |
| `NSStatusItem.view/target/action` | **27 取消弃用** | 自定义绘制的菜单栏 view（迷你图、双行网速）重新成为正式路径 |
| 菜单栏由 MenuBarAgent 渲染为单一窗口 | 平台变化 | 不能用 CGWindowList/窗口号定位 item；`button.window.frame` 仍能给出可用坐标（已验证） |
| 系统溢出指示器 | 平台变化 | 多个宽 item 容易被挤进溢出区 → 默认"合并单 item"或窄 item |
| 实际高度 30 pt，`thickness` 仍为 22 | 平台变化 | 按 `button.bounds` 布局 |
| 用户「允许在菜单栏中显示」 | 26 基线，无读取 API | 用 `removalAllowed` + KVO `isVisible`，并提供 Dock/窗口兜底入口 |
| 已知回归：`occlusionState`、按钮高亮 | 27 bug | 不要依赖这两项 |
| accessory app 弹窗闪退 | 27 行为 | non-activating `NSPanel`，不调用 `activate(ignoringOtherApps:)` |
| 菜单图片默认隐藏 | **27 行为（链接 27 SDK 时）** | 对需要显示的图标设置 `preferredImageVisibility = .visible` |

**运行时实测（gap：menubar-runtime-27）**

| 项 | 结果 | 设计含义 |
|---|---|---|
| 托管方式 | 每个 status item 都是 `NSSceneStatusItem`（FrontBoard scene），由 MenuBarAgent 通过 layer hosting 托管；app 自己不拥有 WindowServer 窗口 | 不能靠窗口 API 观察 item |
| 同尺寸内容更新 | `button.image`、`NSStatusItem.view`、按钮子 view、MenuBarExtra 标签四条路径都能 1 Hz 正常刷新；自绘 view 每次更新约 0.4 ms，image 约 0.9 ms；8 个 item 时 MenuBarAgent 在 120 s 内只多用 0.1–0.3 s | 1 Hz 自绘完全可行，**首选 `NSStatusItem.view`** |
| 宽度变化 | 4 个 item 每秒改宽 → MenuBarAgent 约多占 4–5% 核，WindowServer 也明显增加 | **宽度固定或分档量化**，数字用等宽字体 |
| MenuBarExtra 标签 | 被翻译成按钮的图片 + 标题；标题宽度会变，MenuBarAgent 开销约为 image 路径的 10 倍 | 不适合做多数值自绘 widget |
| `MenuBarExtra(isInserted:)` | 在 27.0 上会 **100% CPU 卡死** | 禁用 |
| WindowServer 日志刷屏 | 每次 item 更新都会打一条 `_CGXPackagesSetWindowConstraints: Invalid window`；覆盖私有 `-[NSStatusBarWindow _needsTilingConstraintUpdate]` 后降到 0–2 条，自身 CPU 也略降 | 属于外观/日志问题；是否用这个私有补丁可以另议 |
| 溢出检测 | 被挤进溢出区的 item 仍是 `isVisible = true`、`occlusionState = visible`，`draw()` 照常调用；`button.window.frame`/`screen` 只能部分反映（会变成 (0,-30)/nil，且可能滞后）；唯一可靠的办法是读 MenuBarAgent 的 AX 树（需要辅助功能权限） | 默认单 item 以避开溢出；被隐藏时 app 要自己降频 |
| 面板定位 | 可见 item 的 `button.window.frame` 与像素吻合；窗口宽 = length + 16 pt；高 30 pt（= 菜单栏高度） | 溢出中的 item 不能拿来锚定面板 |
| `NSPopover` | 链接 27 SDK 时**默认就是 Liquid Glass**（`NSGlassView`，圆角 20） | 最省事的玻璃面板 |
| `NSPanel` + `NSGlassEffectView` | 玻璃正常 | 可拖出成浮窗时用这条路 |
| MenuBarExtra(.window) | SwiftUI 自己绘制玻璃，内部使用 expandedInterfaceDelegate | |
| expanded-interface session | 只有**真实点击**会开始 session，`performClick` 不会；没有公开方法用代码开启（热键打不开）；再次点击 item 或点击别处**不会**自动结束，要 app 自己处理；`cancel()` → `didEnd(animated: true)` | 热键打开面板要走另一条路 |
| 点击事件 | 只能收到全局鼠标事件，本地 event monitor 收不到 | |
| 可见性持久化 | 默认 autosave 名（`Item-N`）会在 init 中恢复 `NSStatusItem VisibleCC Item-N`，旧值为 0 时新 item 会隐藏 | 设置 autosaveName 后显式 `isVisible = true` |
| `systemPrefersReducedResourceUsage` | 本机从未见到 true | 语义仍未知 |

### 3.2 Liquid Glass

| 项 | 版本 | 说明 |
|---|---|---|
| `NSGlassEffectView` / `NSGlassEffectContainerView` / `.glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)` | 26.0 基线 | 27 头文件除下一行外字节级不变 |
| `NSGlassEffectView.effectIsInteractive` | **27 新增** | 仅用于可点击的玻璃元素 |
| SwiftUI `Glass.interactive()` 响应 Mac 鼠标点击 | 27 行为 | |
| 系统玻璃调节滑块（超清 ↔ 全着色） | 27 平台 | 无公开 API；私有 `NSGlassTintAmount`（默认 0.5）可作提示 |
| 移除旧设计逃生口 | 27 | 用 Xcode 27 构建后强制使用新设计 |
| `NSVisualEffectView` | 未弃用 | 仍然是旧材质，不是玻璃 → 新代码别用 |
| 同心圆角 `NSViewCornerConfiguration` / `effectiveCornerRadii` / `GeometryProxy.concentricCornerRadii` | **27 新增** | 卡片圆角跟随面板圆角 |
| 窗口圆角统一收紧、工具栏统一 | 27 平台 | 标准 NSSplitView/NavigationSplitView + 标准工具栏会自动获得新外观 |
| HIG | 26 基线 | 玻璃只用于导航与控件层，内容/图表层用标准材质或不透明填充；只用 `.regular` |

### 3.3 SwiftUI / 数据流 / Charts

- `@State` 改为宏（`LazyState`）：初值只求值一次（已实测：27 SDK 1 次，26.5 SDK 11 次）；不能与其他属性包装器组合使用。
- `withContinuousObservation(options:apply:)`、带选项的 `withObservationTracking`（27）：可在 SwiftUI 之外驱动 status item 重绘，并能只重绘变化的指标。
- AppKit 在 `draw(_:)`/`layout()`/`updateLayer()` 中自动跟踪 `@Observable`（26）。
- `EnvironmentValues.systemPrefersReducedResourceUsage`（27）：降采样/停动画的信号，语义未测，也没有 AppKit/Foundation 等价物。
- `TabsPickerStyle`（27）、`reorderable`/`reorderContainer`（27，SDK 里没有 `apply` 辅助函数）、`.bordered` TextField（27）、`#Preview(arguments:)`（27）；PreviewProvider 在 27 弃用。
- 链接 27 SDK 的行为变化：`LabeledContent` 放在 Menu 里会变成菜单项副标题；Menu/Picker/Slider 不再包装 AppKit 控件；`controlSize` 等环境值在 popover/sheet 内会被重置。
- Charts：27 没有新图表类型；统一的 ContentBuilder（条件内容直接可用）。长历史用 26 的矢量化 `LinePlot`/`AreaPlot`。
- MenuBarExtra / Window / Settings / NSHostingView / NSHostingMenu / NSHostingSceneRepresentation：27 API 零变化。MenuBarExtra 仍不能编程打开、没有右键菜单、不能逐 item 自绘。

### 3.4 其他框架

- WidgetKit：`systemExtraLargePortrait`（27，macOS 可用）；刷新预算约 40–70 次/天（实测放置后 30–45 分钟一次）；扩展**必须沙盒**（本机实测 pkd 拒绝非沙盒扩展）；MacRumors 说的"app 打开时小组件实时更新" **无 Apple 来源支持**。
- AppIntents：`IntentExecutionTargets`（27，可把 intent 固定在主进程执行）、typed `Measurement` 实体属性（温度/功率/频率可暴露给 Shortcuts/Spotlight）。ControlWidget 在 macOS 上自 26 可用。
- MetricKit / StateReporting / Metal 计数器 / ProcessInfo：都只覆盖**本进程**，没有新的系统级遥测。
- Metal：弃用 `isLowPower/isHeadless/isRemovable/location/peer*` 以及设备增删通知（"Not applicable on Apple Silicon"）。
- Mach/BSD：`vm_statistics64` rev6、`rusage_info_v6`（新增 `ri_page_wait_time_mach`、`ri_page_cache_hits`、`ri_conclave_footprint`）、`HOST_CPU_COUNTERS_INFO`/`PROCESSOR_CPU_COUNTERS_INFO`（非特权不可用）、`TASK_VM_SHARED_CACHE_INFO`、`VM_MEMORY_NEURAL` 标签。
- 新框架共 17 个：只有 StateReporting（在 Instruments 中标注自身状态）与本项目略相关。
- 私有库链接：`$(SDKROOT)/usr/lib/libIOReport.tbd`（新增 `IOReportCreateSnapshotDeltas` 导出）、`libSMC.tbd`、`PrivateFrameworks/*.framework` tbd 桩均在；新链接器可链；不要再用 `-ld_classic`。

### 3.5 工具链与隐私

- Swift 6.4；新模板默认 `SWIFT_VERSION=5.0`、Approachable Concurrency、`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`、MemberImportVisibility、`ENABLE_APP_SANDBOX=YES`。采样器必须用 `@concurrent` 或独立 actor，否则会落到主线程。
- 27 是最后一个带通用 Rosetta 的版本；构建只有 arm64。
- 禁止直接读 TCC.db；launchd 拒绝带 quarantine 属性的 plist；默认禁止访问其他团队 app 的容器。
- 本地网络隐私（15+）：launch agent 与 app 都受约束（daemon 不受）→ 局域网 ping/Bonjour 会触发弹窗。
- `hdiutil attach/detach/create/imageinfo` 弃用，改用 `diskutil image …`。

---

## 4. 未决 / 待验证

- Developer ID 签名下 IFLIST2 是否还截断（决定能否继续用 IFLIST2，否则用 IFMIB 即可）
- root helper 能否让 Energy Model 实时（进程可见性和实时功耗都已有无 root 方案，这项只剩学术意义）
- 小组件开发者模式预算豁免（`widgetKitDeveloperModeEnabled`）在自用场景是否可行
- 定位授权后 SSID 的行为；蓝牙授权后 IOBluetooth/CoreBluetooth 能拿到什么
- `systemPrefersReducedResourceUsage` 何时为 true
- 物理显示器下的 DCP FPS
- 沙盒小组件扩展用 `temporary-exception.iokit-user-client-class` 直接读 SMC 是否可行（即使可行也受刷新预算限制）

**已由 critic 标出、现已解决的矛盾**：跨用户进程归因（coalition 可行）、`PHPC` 的构成（SoC 实测总功耗，不是 CPU+GPU）、Energy Model 的评级（实时不可用、30 min 均值可用）、小组件沙盒（实测必须沙盒）。
**仍未定论**：SSD 温度对应哪个 SMC 键（TH0x 与 TN0x 的偏差方向两个 skeptic 相反）→ 以 SMART 为准；Wi-Fi SSID 需要定位、IOBluetooth 受 TCC 管控等行为只在 27 上观察过，无法断定是 27 才引入的。

---

## 5. 模块范围提议（讨论稿）

> 出发点是 §1 里「这台机器实际能测到什么」，不是 Stats 的模块列表。按「采集层 → 数据域 → 呈现面」三层来划分。

### 5.1 采集层（与 UI 无关，非沙盒主进程内）

| 采集器 | 数据源 | 服务的域 | 频率建议 |
|---|---|---|---|
| MachHost | `HOST_CPU_LOAD_INFO`、`host_processor_info`、`vm.page_*` sysctl、`getloadavg`、`vm.swapusage` | CPU、内存 | 1 s（按「字节级相同即陈旧」过滤） |
| IOReportHub | **一个合并订阅**：CPU Complex（`PCPM/MCPM*`）、GPU Stats（`GPUPH`）、PMP0（Energy / DCS BW）、Energy Model（`GPU Energy` 实时 + PMGR 30 min 批次）、Interrupt Statistics（媒体引擎） | CPU、GPU、功耗、内存带宽 | 1 s（每次约 5–8 ms CPU） |
| SMCReader | 启动时全量枚举并缓存 key-info；字节序按属性位判断；只读；按秒对齐采样（SMC 功耗键每秒更新一次，更快的轮询只会读到重复值） | 温度、功耗（RP*/PZ*/PHPC/PDTR）、风扇 | 1 s |
| AppSampler | coalition 全量扫描 + 同 uid libproc 细节 + 进程名/图标 + AGX `AppUsage` | 应用活动（跨域 Top 列表） | 2 s；popover 打开时 1 s |
| IORegistry | pmgr DVFS 表、`H11ANEIn` 状态、`IOBlockStorageDriver`/APFS 卷统计、NVMe SMART、`PowerTelemetryData` | GPU、存储、功耗 | 统计 1 s；SMART 60 s；DVFS 表启动时一次 |
| NetSampler | IFMIB、`SCDynamicStore`、`NWPathMonitor`、`SIOCGIFLINKPARAMS`/LQM、ICMP DGRAM；CoreWLAN **只在打开时读** | 网络 | 1 s；Wi-Fi 细节按需 |
| PowerSources | IOPS（电池/UPS）、CoreHID（UPS 扩展遥测）、私有 IOPS 配件、电源断言 | 电源设备 | 事件驱动 + 去抖 |

所有采集器挂在**一个合并的调度 tick** 上（不要每个 reader 一个定时器）；只在有消费者（菜单栏可见项 / 打开的面板 / 小组件快照）时才采样；`systemPrefersReducedResourceUsage` 或低电量时降频。

### 5.2 数据域（候选模块）

| 优先级 | 模块 | 内容 | 与 Stats 的差异（新能力） |
|---|---|---|---|
| P0 | **CPU** | 总/每核/每簇占用（簇按 perflevel 动态）、实际簇频率、负载均值、Super/M 簇温度与热点、热压力 | 实际频率（PCPM/MCPM）、M 簇温度、热压力 |
| P0 | **GPU 与加速器** | GPU 忙碌、频率、实时功耗、温度（两个分区）、显存；ANE 开/关；媒体引擎编解码活动 | 可信的利用率与频率、媒体引擎 |
| P0 | **内存** | App/联动/压缩/缓存/可用、压力、swap 与换页速率、压缩比、DRAM 带宽 | 换页速率、带宽、rev6 细分 |
| P0 | **存储** | 卷容量（System/Data 分拆、可清除空间）、吞吐与平均延迟、SMART 健康与温度（内置 + 雷电外置）、挂载事件 | System/Data 分拆、事件驱动 |
| P0 | **网络** | 各接口精确吞吐、链路速率/质量、IP/DNS/网关、延迟、Wi-Fi 信号细节 | 64 位精确计数、真实链路速率、链路质量 |
| P0 | **功耗与散热** | 整机实时 DC 功率、墙插功率、SoC 功耗；分部件实时：CPU（按簇）、GPU、DRAM；ANE/媒体引擎显示「最近 30 min」；全部温度分组与热点、风扇转速、热压力、能耗模式、谁在阻止睡眠 | **Stats 在 M5 上没有任何可用的 CPU/ANE/DRAM 实时功耗**；墙插功率、电源断言 |
| P0 | **应用活动**（跨域） | 按应用排序的 CPU / 内存 / 能耗 / GPU / ANE / 磁盘，含 root 与系统守护进程 | **Stats 没有**：统一的每应用视图、GPU/ANE 归因、真实能耗 |
| P1 | **电源设备** | UPS（电量、负载、剩余时间、输入电压）、AirPods 等配件电量、（将来笔记本的）电池 | 桌面机 UPS 一等支持 |
| P1 | **每应用网络流量** | spawn `nettop`（全体）或 NStat（同 uid） | 需要选路线 |
| P2 | **风扇控制** | 自动/手动/曲线 | 唯一需要 root helper 的功能 |
| P2 | **长期历史** | 持久化趋势（小时/天级） | Stats 只有内存里的环形缓冲 |
| P2 | **提醒** | 阈值 + 滞回 + 恢复自动撤回；事件（断网、换网、UPS 切电池） | |
| — | 不做 | Remote/SaaS、自动更新器、蓝牙扫描模块（由电源设备取代）、世界时钟（与监控无关，可另议） | |

### 5.3 呈现面

| 呈现面 | 建议 | 依据 |
|---|---|---|
| 菜单栏 | **默认每模块一个 item，提供合并选项（D06）**；自绘 `NSStatusItem.view`；模板色；宽度固定/分档 | 27 溢出区无公开检测 → 设置里提示合并模式；同尺寸 1 Hz 更新约 0.4 ms，改宽代价高 |
| 面板 | AppKit 外壳：`NSStatusItem`（自绘 `view`，宽度分档）+ `expandedInterfaceDelegate` 驱动开关；面板用 `NSPopover`（27 默认玻璃）或可拖出的 non-activating `NSPanel` + `NSGlassEffectView`；内容用 SwiftUI（GlassEffectContainer 卡片、tabs 切换） | MenuBarExtra 标签宽度可变代价高、`isInserted` 会卡死、不能右键；热键打开需另走路径 |
| 设置 | SwiftUI Settings 场景（`NSHostingSceneRepresentation`）+ `NavigationSplitView` | 自动获得 27 外观 |
| 桌面小组件 | 可选：慢摘要（`systemExtraLargePortrait` 仪表盘）；需 Team ID App Group | 刷新 30–45 min 一次 |
| Control / Shortcuts | 可选：暂停采样、打开面板；typed Measurement 实体供 Shortcuts/Spotlight | `IntentExecutionTargets` |

### 5.4 决策

已于 2026-09-28 拍板，见 `docs/decisions.md`（D01–D13）。要点：风扇控制与桌面小组件为「能力保留、实现靠后」；菜单栏默认每模块一个 item，并提供合并选项；历史数据写盘并支持导出；不显示 Wi-Fi 网络名；其余按推荐执行（私有 API 加自检回退、面板打开时才调用 nettop、Developer ID 签名、常驻开销 <0.5% 单核）。Bundle ID `zone.lyl.sysinfo`。

---

## 附：证据位置

探针源码与 ≤64 KB 的文本输出已拷入仓库：`research/probes/<域>/`、`<域>-review/`、`gap-*/`（文本输出含本机标识，已加入 `.gitignore`，只保存在本地）；WWDC26/发布说明的文本快照在 `research/probes/web-release-notes/`。原始大日志与二进制未保留。

---

## 后续决策注记（2026-09-28，启动实现时补）

本报告正文在 D01–D13 拍板时做过少量同步（开头的定位说明、§2.1 与 §5.3 中的 D06、§5.4），此后不再修改。下面只列主要的被取代项，并非完整清单；凡与 `docs/decisions.md` 冲突之处，都以决策档为准。

- §3.1 中「默认单 item」的建议（系统溢出指示器一行、溢出检测一行）→ D06：默认每个模块一个 item，并提供合并选项。
- §5.2 把长期历史列为 P2 → D08：已提前为已定能力。§5.2 中每应用网络流量「需要选路线」→ D09：面板打开时调用 nettop。
- §5.1 让 IOReportHub 以 1 s 合并订阅常驻；§5.1、§5.4 中的「常驻 <0.5%」和降频要求 → D19：开销预算只约束出厂默认配置；显示项和采集频率由用户选择，开销由用户承担；降频条款也已修订。附实测开销：单个 PMGR 类分组每次约 4.2–5.3 ms CPU，四组合并订阅每次约 8.25 ms。
- §5.3 面板「NSPopover 或 NSPanel」→ D21：统一使用 NSPanel 面板。
- §1.7「蓝牙设备 + 电量（CLI）」用 `system_profiler` → D22：不调用 `system_profiler`。
- 全文只在 Mac17,16（M5 Pro）上实测。D20 要求支持多台 Apple 芯片 Mac，与芯片或机型相关的结论（RP* 等 SMC 键、IOReport 通道名、DVFS 表键、HID 传感器、核拓扑、风扇、电池等）要在各模块实现时复核。
- §0-6 和 §4 中以下验证项已不需要再做：Developer ID 签名下 IFLIST2 是否截断（D11 已定一律用 IFMIB）；root 下 Energy Model 是否实时（D04 规定 root 只用于风扇）；定位授权后的 SSID（D10）；蓝牙授权后的能力（D13、D22）；物理显示器下的 DCP FPS（D13 的模块范围里没有使用者）。
- 附录「证据位置」：`web-release-notes/`、`verify-web-release-notes/` 等处的网页与文档快照（`.txt/.json`）只保存在本地，没有进入版本库；版本库里只有 `sdk-swiftui/` 下两份 `.md` 发布说明副本。
