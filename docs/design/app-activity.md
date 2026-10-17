# 应用活动模块设计

> 日期：2026-10-17。状态：§1 是开工前的补测，§2 是待用户拍板的能力边界。
> 前置决策：D13（P0 跨域视图）、D29 §「划给应用活动」、D30（`app_minute`、30 天保留）、D31（按应用分组、结束进程）、D44（电源断言留给应用活动或 P1）、D58（槽位 39）、D64 §应用活动（独立窗口、面板只放入口）、D65 MG5（总览只用常驻采集器）。
> 探针：`research/probes/app-activity/`，M5 Pro 与 M4 Pro 各跑一次（同一天，各自的日常负载）。

## 1. 补测（M5 Pro、M4 Pro，macOS 27.0.1）

已有结论不再重测：coalition 槽位含义与自检（调研报告 §1.8、`AppSampler`）、Top N 的扫描与名字解析开销（`cpu-module/processes/scan_cost.c`）、槽位 39 与 PMGR ANE 对账（D58）、槽位 41 与 AGX 逐焦耳相等（D57）。

### 1.1 电源断言（`assert_watch.c`）

- `IOPMCopyAssertionsByProcess`（公开）能看到**所有用户**的断言：root（powerd、某远程桌面软件的 root 部分）、`_coreaudiod`（uid 202）、`_windowserver`（88）、`_spotlight`（308）都在。每个断言的 pid 都能用 `PROC_PIDCOALITIONINFO` 映射到 coalition（39 条全部成功），可以直接并入按应用的分组。
- 开销：`IOPMCopyAssertionsByProcess` 线程 CPU 中位数 M5 0.28 ms / M4 0.33 ms（墙钟 0.76 / 0.85 ms，走 powerd 的 XPC）；`IOPMCopyAssertionsStatus`（只有汇总的类型 → 0/1）0.09 / 0.18 ms。M4 上同样能看到 root、uid 88、202 的断言，全部能映射到 coalition。
- 要处理的数据形态：
  - **重复**：某远程桌面软件一个 root 进程同时挂了 28 条（M4 为 12 条）同名的 `UserIsActive`（超时 0，不断续期）。显示时要按「进程 + 类型 + 名字」合并计数。
  - **代他人持有**（两台都有）：coreaudiod 的断言带 `AssertionOnBehalfOfPID`（指向某远程桌面软件的用户进程）。这类断言应该算到被代理的应用上，并注明「经 coreaudiod」。
  - `AssertType` 与 `AssertionTrueType` 可能不同（某应用的 `NoIdleSleepAssertion` 实为 `PreventUserIdleSystemSleep`），按 TrueType 归类。
  - `UserIsActive`、`ExternalMedia`、`BackgroundTask` 这类不阻止睡眠，「阻止睡眠」只算 `PreventUserIdleSystemSleep`、`PreventSystemSleep`、`PreventUserIdleDisplaySleep`（另列「阻止显示器睡眠」）。
- 变化通知：notify(3) 的 `com.apple.system.powermanagement.assertions.anychange` **默认不发**（自建 / 释放断言、派生 `caffeinate` 都收不到）。先调用私有的 `IOPMAssertionNotify(name, 1)` 向 powerd 登记，之后自己的与别的进程的断言出现 / 消失都在 0.5–11 ms 内触发（两台一致；进程退出时登记自动失效）。M4 上登记后约 135 ms 会先收到一次与断言无关的通知，处理时只当作「去重新读一次」。
- 私有的断言活动日志（`IOPMCopyAssertionActivityLog` / `…Update`，能查到过去谁持有过）在两台上都返回 `kIOReturnNotPermitted`，读不到。所以「过去谁阻止过睡眠」只能由本 app 运行期间自己记录。
- 内核侧断言（IOPMrootDomain `DriverPMAssertionsDetailed`）在 27 上（M5 22 条、M4 15 条）`ModuleName` / `Name` 全空，只剩位掩码，没有可展示的归属，不用。

### 1.2 每分钟的活跃应用密度与历史行数（`appact_density.c`，10 分钟，10 s 窗口，第 5 分钟起 30 s 6 线程压测）

| 指标 | M5 Pro | M4 Pro |
|---|---|---|
| 解析到的身份（bundle / 可执行文件路径） | 574（有成员的 coalition 约 660） | 575（约 660） |
| 每分钟有 CPU 用量的身份 | 平均 172（151–212） | 平均 151（126–182） |
| 每分钟各列非零的身份 | CPU 172、唤醒 151、磁盘 8.3、GPU 2.1、pageins 1.1、ANE 0 | CPU 151、唤醒 136、磁盘 5.3、GPU 1.0、pageins 0.1、ANE 0 |
| 「各列前 K 名取并集」每分钟的行数 | K=5：9.8；K=10：20.9（18–24）；K=20：40.6 | K=5：11.6；K=10：22.6（19–26）；K=20：46.9 |

各方案对每列总量的覆盖（每分钟平均，M5 / M4）：

| 方案 | CPU | CPU 能耗 | GPU | 磁盘 | 唤醒 | pageins | 内存（footprint） |
|---|---|---|---|---|---|---|---|
| 现行：只存 CPU 前 10 | 0.919 / 0.945 | 0.926 / 0.952 | 1 / 1 | 0.943 / 0.926 | 0.894 / 0.957 | **0.200** / 1.000 | **0.492 / 0.583** |
| 各列前 10 取并集 | 0.956 / 0.958 | 0.963 / 0.966 | 1 / 1 | 1 / 1 | 0.973 / 0.979 | 1 / 1 | 0.725 / 0.695 |
| 各列前 20 取并集 | 0.981 / 0.984 | 0.983 / 0.988 | 1 / 1 | 1 / 1 | 0.990 / 0.990 | 1 / 1 | 0.788 / 0.753 |

- M4 的 pageins 在 10 分钟里几乎为 0（每分钟 0.1 个身份），所以覆盖率 1.000 没有区分度；M5 上出现过 pageins 时，CPU 前 10 只覆盖了 20%。

- 内存是存量，分散在 574 个身份上，任何前 K 方案都覆盖不全；但前 10 已经包含所有大户（按 footprint 排序的意义在于大户）。
- 体积估算（30 天分钟级，按每行约 60 字节、9 个整数列）：现行 10 行 ≈ 15 MB（只有 2 列）；并集前 10（约 21 行）≈ 55 MB；并集前 20 ≈ 105 MB；全部活跃（172 行）≈ 450 MB。

### 1.3 能耗口径：应用能耗合计对 SoC / 整机的覆盖

Σ（槽位 11 CPU 能耗 + 41 GPU 能耗 + 39 ANE 能耗）÷ 窗口长度，对比同窗口 SMC `PZC0`（SoC）与 `PDTR`（整机直流）的平均值：

| 状态 | 机器 | 应用合计 | SoC | 合计 ÷ SoC | 合计 ÷ 整机 |
|---|---|---|---|---|---|
| 空闲 | M5 | 0.15–0.26 W | 0.67–1.34 W | 0.23–0.27 | 0.02–0.03 |
| 空闲 | M4 | 0.02–0.06 W | 0.23–0.44 W | 0.10–0.19 | 0.007–0.017 |
| CPU 压测（6 线程） | M5 | 16.2–17.1 W | 17.7–18.9 W | 0.905–0.916 | 0.63 |
| CPU 压测（6 线程） | M4 | 15.7–16.4 W | 15.7–16.9 W | 0.971–0.995 | 0.73 |

- 空闲时 SoC 功率的大部分不属于任何应用（M5 约 3/4，M4 约 9/10；fabric、显示、DRAM 控制器等静态部分），整机直流里应用只占 1–3%。比例随芯片不同，所以不能拿一台的系数去推另一台。所以「每应用能耗」只能是「该应用的 CPU + GPU + ANE 能耗」，**不能**表述成占整机或占 SoC 的百分比；Activity Monitor 的「能耗影响」「12 小时功耗」来自 sysmond（需要 Apple 私有 entitlement，调研报告 §0-3），拿不到。

### 1.4 全表刷新开销（`appact_cost.c`，utility QoS，真实节奏）

原始线程 CPU，M5 / M4（两台都约 660 个有成员的 coalition）：

| 模式 | 每次 | 1 s | 2 s | 5 s |
|---|---|---|---|---|
| A 只扫描（列表 + 每个读资源用量） | 6.1–6.4 / 7.4–7.6 ms | 0.64 / 0.74% | 0.31 / 0.38% | 0.12 / 0.15% |
| B 扫描 + 全部冷解析（成员 + 路径） | 11.6–11.8 / 16.6–17.1 ms | 1.16 / 1.66% | 0.59 / 0.84% | 0.23 / 0.34% |
| C 扫描 + 按 cid 暖缓存（稳态） | 6.4 / 7.4–7.9 ms | 0.64 / 0.74% | 0.32 / 0.39% | 0.13 / 0.16% |
| D 扫描 + 每次取全部成员列表 | 6.8–6.9 / 8.0–8.5 ms | 0.68 / 0.80% | 0.34 / 0.43% | 0.14 / 0.17% |

- M4 的值是原始 CPU 时间，utility QoS 下大多跑在能效核上；按 D40 的最快档等效口径会更低，实现后用 `make measure` 复核。
- 冷解析只在窗口第一次打开时付一次（M5 约 +5.5 ms，M4 约 +9 ms），之后按 cid 缓存；成员数要实时显示时每次多约 0.4 ms。图标与本地化名另按 bundle 缓存，不计入。
- 扫描本身随 coalition 数线性，与「只显示 Top N」时相同，所以窗口开着的开销和 CPU 面板开着时相当。

## 2. 待拍板（AA1–AA8）

### AA1 表格的列
- **A（推荐）**：CPU（% 单核与累计时间）、内存（footprint）、能耗（W，§1.3 口径，列名「功率」）、GPU（时间占比）、ANE（功率，估算）、磁盘读 / 写、唤醒（次/s，槽位 4+5）、阻止睡眠（图标，AA5）。perflevel0 占比、pageins、成员数可在列菜单里打开，默认隐藏。P1 加网络列。
- **B**：只做 CPU、内存、能耗、磁盘四列，其余进应用详情。

### AA2 能耗合计的呈现
- **A（推荐）**：每行显示 W；表格底部一行「应用合计 x W · SoC y W」，不给百分比，tooltip 说明未归属部分是什么（§1.3）。
- **B**：另加一行「未归属」= SoC − 合计（空闲时会占 75%，容易误读）。

### AA3 每应用历史存什么（修订 D30 的「每分钟只存 CPU 前 10」）
- **A（推荐）**：`app_minute` 加列（GPU 时间、GPU / ANE 能耗、磁盘读 / 写、唤醒、footprint 最大值），每分钟存「各列前 10 的并集」（M5 约 21 行，M4 约 23 行），另存一行「其余合计」让各列总量可还原。30 天约 55 MB。
- **B**：并集前 20（约 41 行，覆盖 CPU 98%，约 105 MB）。
- **C**：维持现状（只 CPU 前 10，两列，15 MB；内存覆盖 49%、pageins 20%）。

### AA4 窗口的时间段
- **A（推荐）**：现在 / 1 小时 / 今天 / 7 天 / 30 天（分钟数据保留 30 天，查询全读 `app_minute`）。「现在」是实时扫描，其余读历史库，含已退出的应用；面板关闭时历史仍按 D30 每 10 s 采。
- **B**：照合并模式稿 §6 的四档（不含 30 天）。

### AA5 电源断言（阻止睡眠）
- **A（推荐）**：窗口可见时用公开的 `IOPMCopyAssertionsByProcess` 显示当前断言（与扫描同节奏）；后台另用私有的 `IOPMAssertionNotify` 登记变化通知（放进 `CSysPrivate`，带自检：登记后自建 / 释放一次断言看通知是否到达），事件驱动地把「开始 / 结束」写进历史库，用来回答「今天谁阻止过睡眠、多久」。通知自检不过时退回后台每 60 s 轮询公开接口（短于 60 s 的断言会漏）。
- **B**：只显示当前断言，不记历史（全公开 API）。
- **C**：不做，留给 P1。

### AA6 侧栏分类
- **A（推荐）**：全部 / App（有 .app bundle）/ 后台与系统 / 阻止睡眠。「唤醒最多」只是按唤醒列排序，不单列分类。
- **B**：照设计稿 §6 的「全部 / 阻止睡眠 / 唤醒最多」。

### AA7 「现在」档的采样间隔
- **A（推荐）**：默认 2 s（M5 0.32%、M4 0.39% 单核，只在窗口可见时），可选 1 / 5 s，设置里标注开销（D19）。
- **B**：默认 1 s（M5 0.64%、M4 0.74%）。

### AA8 总览的「最耗能的 3 个应用」卡片与 MG5 的冲突
D65 MG5 规定总览「只用常驻采集器，不扫 Top N」，而这张卡片需要 coalition 数据。
- **A（推荐）**：卡片复用后台历史已有的 10 s 扫描（D30 记录每应用时本来就在扫），显示最近 1 分钟的前 3，不新增采样；关掉每应用历史时卡片不出现。
- **B**：总览可见时另按 5 s 扫描（约 0.13–0.16% 单核），算是 MG5 的例外。

### 默认做法（无异议即采纳）
- 分组、结束进程、回退沿用 D31；宿主 coalition（终端、Xcode）在历史里仍记在宿主名下，实时表格副标题显示占比最高的成员。
- 身份按 bundle id / 可执行文件路径合并（`AppIdentity`），已退出应用照常出现在历史时段里。
- 表格排序固定按用户选的列，「现在」档每次刷新不重排已选中行的位置（选中行保持可见）。
- 窗口不占菜单栏 widget；不进出厂默认开销预算（窗口关闭时为 0）。

## 3. 实现方案（D67–D70 拍板后）

### 3.1 采集层（SysCollectors）
- `CoalitionUsage` / `CoalitionDelta` 补字段：唤醒（槽位 4 + 5）、pageins（49）的差分，footprint（40）与累计 CPU 时间的当前值。全表与历史都从同一个窗口取，不另做扫描。
- `AppActivityBuilder`：把一个窗口变成全表行（`AppActivityRow`）。身份按 cid 缓存（名字、.app 路径、bundle 键、是否 App、代表 pid），只解析新 cid；成员数取 `proc_listcoalitions` 的 tasks。计算全在后台（utility），不碰 MainActor。
- `PowerAssertionCollector`（`app.assertions`，inline）：
  - `sample()` 用公开的 `IOPMCopyAssertionsByProcess` 读当前断言，归类、合并重复、按 `AssertionOnBehalfOfPID` 改归属，pid → coalition；输出断言快照（不出数值样本）。
  - `selfTest()`：符号解析（`csp_pm_assertion_notify_register`，dlsym `IOPMAssertionNotify`）→ 登记 → 自建并释放一次 `PreventUserIdleDisplaySleep` 断言（名字「SysInfo self-test」）→ 1 s 内是否收到 `anychange`。通过则进入事件驱动；不过时状态降级，由历史记录器改为每 60 s 登记需求轮询。
  - 事件驱动：`notify_register_dispatch` 在采集器自己的串行队列上回调，回调里读一次快照，经回调交给订阅方（历史记录器）。同一 100 ms 内的多次通知合并。
- 私有符号只有 `IOPMAssertionNotify` 一个，放 `CSysPrivate/pm.c`，D35 的 dlsym 方式。

### 3.2 历史层（SysStore，schema v3）
- `app_minute` 加列：`gpu_ns`、`gpu_nj`、`ane_nj`、`disk_r`、`disk_w`、`wakeups`、`footprint`（都可空，旧行为空）。
- `MinuteAggregator` 每应用桶扩到全部列；`take()` 每分钟取「CPU、功率、GPU、ANE、磁盘、唤醒、footprint 各前 10」的并集，另写一行 `__other__`（其余合计；footprint 取和）。
- 记录器为每个窗口解析「各列前 16 的并集」的身份（原来只看 CPU 前 16）。
- 新表 `power_assertion(id, app, type, name, holder, start_s, end_s)`：快照比较得到开始 / 结束；启动时把上次运行遗留的未结束行按上次提交时刻收尾（标记 `end_estimated`）。保留期同分钟级。
- 查询：`appTotals(from:to:)`（按应用汇总各列；footprint 取最大）、`appSeries(app:metric:)`（详情图表）、`assertionSpans(from:to:)`。导出加新列与断言表。
- 记录器另维护最近 60 s 的每应用功率（从它收到的窗口算），给总览卡片用（D70），不额外采样。

### 3.3 app 层
- `AppActivityModel`：窗口可见时登记 `app.coalition` + `app.assertions` 需求（默认 2 s）；历史时段读记录器；排序、搜索、分类、选中保持。
- `AppActivityWindowController`：标准 `NSWindow` + SwiftUI（侧栏：时间段与分类；主体：`Table`；右侧：应用详情 inspector）。打开期间与设置窗口共用一个「前台窗口计数」决定 `.regular` / `.accessory`。
- 入口：各 Top N 底部「在应用活动中查看全部 ›」（按该模块列排序）、面板顶栏按钮、总览「最耗能的 3 个应用」卡片（D70）。
- 设置：新增「应用活动」模块页（采集间隔、列的默认显示、是否记录每应用数据与电源断言）；「记录每应用数据」从 CPU 页移来（D41：一处可编辑，CPU 页改为只读引用）。诊断页加断言数据源状态。
- 启动参数 `--open-app-activity[=<时间段>]`，截图与开销测量用。
- CLI：`apps`（现在 / 历史时段全表）、`assertions`（当前断言与自检）。

## 4. 偏离记录（实现中）

- **2026-10-17 coalition 自检 S4 的误判（影响 CPU 模块）**：`AppSampler.slotCrossCheck` 原来比对全部「同 uid、当前只有 1 个成员」的 coalition，但有成员退出过的 coalition 累计值包含已退出成员的用量，本来就比现存成员大。M5 实测同 uid 单成员 345 个：`tasks_started ≤ 2`（launchd 拉起一个进程时就是 2）的 294 个槽位全部与 rusage 一致，`> 2` 的 52 个里 51 个不一致；不排除时能耗只有 51/60 一致，S4 判为不过，**能耗、perflevel0 相关的列被整体隐藏**（CPU Top N 的能耗列、历史库的 `energy_nj` 记成空值）。改为只比对 `tasks_started ≤ 2` 的 coalition，并把 rusage 在读槽位前后各读一次（落在两次之间即算一致）。修复后两台都是 60/60。之前因此记成空值的历史能耗，在历史时段里按「只计已知部分」显示，带「*」并说明。
- **时间段放在工具栏**：合并模式稿 §6 写「左侧：时间段与分类」。实现时时间段用工具栏的分段控件，侧栏只放分类：两者都是单选，放在同一个侧栏列表里只能高亮一个。
- **设置侧栏新增「应用活动」页**（D27 的侧栏顺序里，网络之后、历史与导出之前）：窗口入口、「现在」档间隔、「记录每应用数据与电源断言」（偏好键仍是 `history.apps.enabled`，从 CPU 页移来，CPU 页改为只读引用，D41）。
- **面板顶栏加「应用活动」按钮**（D64 留到实现时看空间）：放在「活动监视器」左边。
- **私有层版本 `CSP_LAYER_VERSION` 改为 2**（新增 `csp_pm_*`）。此前加入 IOReport、SMC、coalition 时一直是 1，没有递增。
- **断言自检每次都会自建一个断言**：启动、唤醒、系统 build 变化时的自检会创建并释放一个 `PreventUserIdleDisplaySleep`（名字「SysInfo self-test」，几毫秒），读取时滤掉，不进历史。
- **schema 3 之前的每应用行**：新列为空。内存峰值显示「—」，GPU、ANE、磁盘、唤醒按 0 计。
- **历史库能耗的显示**：分钟里 CPU 能耗为空（槽位核对未通过）时，按应用汇总只计已知分钟，标「*」；小于 1 Wh 的能耗用 mWh 显示。
- **启动参数**：`--open-app-activity[=<时间段>]`、`--app-activity-select=<n>`（截图自查用）。measure 脚本加 `appactivity` 档。
- **runningboardd 的启动记账不算阻止睡眠**（2026-10-17 点击验收时发现）：每个 app 启动、退出时，runningboardd 都会代它持有一个 2–3 s 的 `PreventUserIdleSystemSleep`（名字形如 `app<application.…>…:FBApplicationProcess`），任何 app 都有，混进来只是噪音。读取时滤掉；Debug 历史库里修复前记下的 8 段已删除。
- **右键菜单打开期间暂停表格刷新**，关闭后补一次；**从入口带着排序列打开窗口时清掉选中、回到顶部**（否则停在上次选中的行附近，最大的几项不可见）。

