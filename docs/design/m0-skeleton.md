# M0 骨架设计

> 依据：D15（M0 范围）、D16（标识）、D19 与 D25（调度、频率粒度、降频）、D21（面板）、D22（隐私）、D23（工程基线）、D24（K17 数据模型、K18 调度、K19 诊断、K20 降频、K24 格式、K25 测试、K26 开销度量、K29 日志、K30 Makefile、K31 快照类型、K32 菜单栏 item）。
> 本文档是 M0 的实现规格。与决策档冲突时以决策档为准；实现中发现必须偏离本文档的地方，要在文末「偏离记录」里写明原因。

## 1. 目标与验收

M0 用来验证外壳：接入公开 API 的 CPU 总占用，从采集、调度、菜单栏 item、面板、设置、诊断，到开销计数，全链路跑通。M0 **不**建私有 C 层的实际调用，**不**做 CPU 拓扑与簇映射（那是 CPU 模块的能力边界，开工时再讨论），也**不**做历史存储。

验收清单：
1. `make build`、`make test` 通过；Swift 6 语言模式下零警告（第三方和系统头文件的警告除外）。
2. Debug 版 `SysInfo Dev`（`zone.lyl.sysinfo.dev`）启动后：
   - 没有 Dock 图标，菜单栏出现一个固定宽度的 CPU item，1 Hz 刷新，数值与 `top -l 2 -s 1` 的 CPU 行误差在几个百分点以内。
3. 面板交互：
   - 真实点击 item 会打开玻璃面板；再次点击 item、点击别处、按 Esc 都能关闭。
   - 面板上的「固定」按钮可以把面板变成独立浮窗（有关闭按钮）。
   - Debug 下用 `--open-panel` 启动时，不经点击直接打开面板。
4. 设置窗口：
   - 重新打开 app 时弹出设置窗口；窗口打开期间 app 有主菜单，⌘, 和 ⌘Q 可用；关闭后恢复为无 Dock 图标。
   - 侧栏按 D25 排布。诊断页能看到采集器状态、每次采样耗时，以及 app 自身的 CPU 占用和内存。
5. 采样只在有消费者时进行：菜单栏 item 被隐藏且面板关闭时，调度器停掉定时器，不再唤醒。
6. `sysinfo-cli` 在本机和 Mac Studio（M2 Max，`ssh user@remote-host`）上都能构建运行，自检通过，数值与各自的 `top` 对得上。
7. 用 `make measure` 测出出厂默认配置（1 个 item）和面板打开两档的开销，结果写入 `docs/perf/m0.md`；默认配置应低于 0.5% 单核（D19）。

## 2. 仓库布局

```
SysInfo.xcodeproj/              app target「SysInfo」；App/ 用同步文件夹（PBXFileSystemSynchronizedRootGroup）
  xcshareddata/xcschemes/SysInfo.xcscheme
Config/
  Shared.xcconfig               公共设置
  Debug.xcconfig                #include "Shared.xcconfig"；Bundle ID .dev、显示名 SysInfo Dev
  Release.xcconfig              #include "Shared.xcconfig"
App/                            app 源码（默认 MainActor 隔离）
  SysInfoApp.swift              @main AppDelegate
  MenuBar/  Panel/  Settings/  Diagnostics/  Support/
  Localizable.xcstrings
Packages/SysKit/                本地 Swift Package（默认 nonisolated）
  Package.swift
  Sources/CSysPrivate/          C target：M0 只放占位头文件和 .c，不声明任何私有符号
  Sources/SysModel/             值类型：MetricID、Sample、DataQuality、CollectorHealth、WidgetSnapshot…
  Sources/SysCollectors/        调度器、采集器协议、CPU 负载与自身开销采集器、降频信号
  Sources/sysinfo-cli/          命令行，用于跨机对照
  Tests/SysModelTests/  Tests/SysCollectorsTests/
Makefile
scripts/measure-overhead.sh
docs/perf/m0.md
```

- 对 app 只暴露 `SysModel` 和 `SysCollectors` 两个 library product。`CSysPrivate` 不做成 product，app 在编译期就 import 不到它（D23）。
- `SysStore`（历史存储）到 CPU 模块再建。

## 3. 构建设置（Config/Shared.xcconfig）

- 部署与架构：`MACOSX_DEPLOYMENT_TARGET = 27.0`，`ARCHS = arm64`。
- 语言：`SWIFT_VERSION = 6.0`；`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（仅 app target）；保留 Xcode 27 模板的 Approachable Concurrency 和 MemberImportVisibility。
- 沙盒与签名：`ENABLE_APP_SANDBOX = NO`，`ENABLE_HARDENED_RUNTIME = YES`；`CODE_SIGN_STYLE = Manual`，`CODE_SIGN_IDENTITY = Developer ID Application`，`DEVELOPMENT_TEAM = D8MFB2YNN3`。
  - Debug 保留 Xcode 注入的 get-task-allow；不加 disable-library-validation。
- Info.plist：`GENERATE_INFOPLIST_FILE = YES`，`INFOPLIST_KEY_LSUIElement = YES`，`INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities`。
- 标识与版本：`PRODUCT_NAME = SysInfo`；`MARKETING_VERSION = 0.1.0`；`CURRENT_PROJECT_VERSION` 默认为 1，由 Makefile 用 `git rev-list --count HEAD` 覆盖。
  - Debug：`PRODUCT_BUNDLE_IDENTIFIER = zone.lyl.sysinfo.dev`，`INFOPLIST_KEY_CFBundleDisplayName = SysInfo Dev`。
  - Release：`zone.lyl.sysinfo`、`SysInfo`。
- 本地化：工程的 development region 为 `zh-Hans`，`SWIFT_EMIT_LOC_STRINGS = YES`。
- Package：`swift-tools-version` 用本机工具链支持的最新版本，`platforms: [.macOS("27.0")]`（或对应枚举），Swift 6 语言模式。

## 4. 数据模型（SysModel，K17）

- `MetricID`：包一层 `String` 的可哈希值类型，点分命名，例如 `cpu.usage.total`、`cpu.usage.core.<n>`、`app.self.cpu`、`app.self.footprint`。它贯穿环形缓冲、将来的历史库、导出列名和小组件快照。
- 单位与数值：
  - 数值一律是 `Double`，用 SI 基本单位；占用率用 0…1 的比例，只在 UI 层格式化。
  - `DataQuality` 枚举：`measured`、`batched30min`、`estimated`、`relative`、`inferred`、`unavailable(reason)`。不可用用这个显式状态表示，不用 0 或 NaN 代替。
- `Sample`：包含 `id`、`value`、`quality`、单调时钟时间（用于差分）和 UTC 墙钟时间（用于历史）。
- 采集器状态：
  - `CollectorID`：包一层 `String`，例如 `cpu.load`、`app.self`。
  - `CollectorHealth`：包含 id、状态（ok / degraded / unavailable）、当前数据路径的说明、自检结果、最近一次和平均的采样耗时（墙钟与线程 CPU 时间），以及陈旧计数。
- `WidgetSnapshot`（Codable）和 `SnapshotSink` 协议（默认实现什么都不做），先占好位置（K31）。
- 所有类型都是 `Sendable`。

## 5. 采集与调度（SysCollectors，K18、D19、D25）

### 5.1 采集器
```swift
protocol Collector: AnyObject {            // 实例归 SamplingEngine 这个 actor 所有，不跨隔离域传递
    var id: CollectorID { get }
    func selfTest() -> SelfTestResult      // 启动、唤醒、系统 build 号变化时复检（K19）
    func sample(at t: SampleTime) -> CollectorOutput   // 返回 [Sample] + 健康信息
}
```
- **CPULoadCollector**（`cpu.load`）
  - 数据源：`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，读每核 tick 并差分；总占用取所有核之和。不用 `HOST_CPU_LOAD_INFO`，它受全局节流（§0-7）。
  - 返回的数组必须 `vm_deallocate`。
  - 如果本次读数与上次逐字节相同，视为陈旧：跳过本次，计入陈旧计数。
  - 某核 tick 出现回退（负差）时按计数器复位处理：丢弃这一段，不钳为 0。
  - M0 只输出总占用和每核占用，不做 perflevel 或簇的映射。
- **SelfUsageCollector**（`app.self`）
  - 数据源：`proc_pid_rusage(getpid(), RUSAGE_INFO_V6)`，差分 `ri_user_time + ri_system_time` 得到本进程 CPU（按单核的比例），并读取 `ri_phys_footprint`。
  - 时间单位用 `mach_timebase_info` 换算，不写死 125/3。

### 5.2 SamplingEngine（actor）
- 需求注册：`addDemand(Demand) -> DemandToken`，token 释放即注销（`deinit` 或显式 `cancel()`）。
  - `Demand` 包含：采集器集合、间隔（基础 tick 的整数倍），以及来源标签（`menubar.cpu`、`panel`、`diagnostics`…）。
  - D25 的「全局默认 + 逐模块覆盖」在 app 层换算成各消费者的间隔，引擎只看 Demand。
- 定时器：
  - 基础 tick 为 1 s，由一个 `DispatchSourceTimer` 驱动，放在私有串行队列上，设 leeway（约 100 ms）。
  - 首次触发对齐到下一个整秒之后约 50 ms（SMC 类数据源每秒更新，将来沿用）。
  - 没有任何需求时，挂起定时器，不再唤醒。
- 每个 tick：
  - 按需求算出本次到期的采集器，每个采集器在本 tick 最多跑一次（取所有需求里最短的间隔），并串行执行。
  - 记录每个采集器的墙钟耗时和线程 CPU 耗时（`clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)`）。
  - 一个 tick 的全部结果打包成一个 `TickResult`，只交付一次给订阅者（`AsyncStream` 或回调），由 app 在 MainActor 上写入存储。
- 降频：`setThrottle(factor:reasons:)`。factor 为 2 时，所有间隔乘 2；`paused` 表示锁屏或显示器睡眠，此时只保留标记为 `.background` 的需求（M0 还没有这类需求，等于全停）。
- 「本次到期」的计算写成纯函数，方便单测。

### 5.3 降频信号（K20，D25：默认开启、可关闭）
- 触发信号：
  - `ProcessInfo.isLowPowerModeEnabled`（监听 `NSProcessInfoPowerStateDidChange`）；
  - `thermalState` 为 `.serious` 及以上；
  - UPS 或电池放电：`IOPSNotificationCreateRunLoopSource` + `IOPSGetProvidingPowerSourceType`，去抖 5 s；
  - 锁屏：分布式通知 `com.apple.screenIsLocked`/`Unlocked`；
  - 显示器睡眠：`NSWorkspace.screensDidSleepNotification`/`screensDidWake`。
- 每次信号变化都写日志，顺带回答调研报告 §4「`systemPrefersReducedResourceUsage` 何时为 true」。这个信号本身 M0 可以先不接，在偏离记录里说明即可。
- 信号的汇总放在 app 层（`ThrottleMonitor`），再调用引擎的 `setThrottle`。

## 6. App 层（MainActor）

- **入口**：`@main` 的 `NSApplicationDelegate`，负责创建 `AppSettings`、`MetricStore`、`SamplingEngine`、`StatusItemController`、`PanelController`、`SettingsController`、`ThrottleMonitor`。
  - `applicationShouldHandleReopen` 时打开设置窗口。
  - 启动时如果没有任何启用的 item，也打开设置窗口。
- **AppSettings**：`@Observable`，底层是 `UserDefaults.standard`；Debug 与 Release 的 Bundle ID 不同，存储天然隔离。M0 的设置项：
  - 全局默认采集间隔（1、2、5 s）；
  - CPU 模块的间隔覆盖（跟随全局，或指定 1、2、5 s）；
  - CPU item 是否显示；
  - 是否自动降频（默认开）。
- **MetricStore**：`@Observable`，保存每个 `MetricID` 的最新 `Sample`、各采集器的 `CollectorHealth`、调度状态（tick 数、有效需求、降频因子与原因）。另有内存环形缓冲：按「时间戳 + 值」逐条存样本，不假设采样间隔固定，每个指标保留 15 分钟（K39 的倾向值，CPU 模块再定）。
- **菜单栏 item**（K32、D06）：
  - 创建：`NSStatusItem(withLength:)` 用固定宽度，按最坏情况的字符串（如 `CPU 100%`）算好宽度，运行中不改。`autosaveName = "<bundle id>.cpu"`，创建后显式设 `isVisible = true`，`behavior = .removalAllowed`；通过 KVO 观察 `isVisible`，用户把 item 拖走后，同步关掉设置里的开关。
  - 绘制：自绘 `NSView` 子类作为 `statusItem.view`。数字用 `monospacedDigitSystemFont`，按 `button.bounds`（实际 30 pt 高）排版，文字颜色用语义色（`labelColor`）。在 `draw(_:)` 里直接读 `MetricStore`，由 AppKit 自动跟踪 `@Observable` 并刷新。
  - 需求：item 可见时注册 `cpu.load` 需求，隐藏时注销。
- **面板**（D21，参考 `research/probes/gap-menubar-runtime-27/mbprobe.swift` 的 `PopupCtl`）：
  - 打开与关闭：由 `NSStatusItemExpandedInterfaceDelegate` 驱动：`statusItem(_:didBegin:)` 时显示，`statusItemDidEndExpandedInterfaceSession(_:animated:)` 时隐藏。
    - 实测系统不会自动结束 session：点击别处要靠全局鼠标监视器（`NSEvent.addGlobalMonitorForEvents`，鼠标事件不需要辅助功能权限），按 Esc 靠本地键盘监视器，这两种情况都调用 `session.cancel()`。
    - 再次点击 item 时，如果面板已开就关闭。
  - 窗口：单个可复用的 `NSPanel`，styleMask 为 `[.borderless, .nonactivatingPanel]`，`level = .popUpMenu`，背景透明，有阴影，`contentView` 是 `NSGlassEffectView`（cornerRadius ≈ 18），内部放 `NSHostingView`。定位锚在 `button.window.frame` 下方，并限制在屏幕 `visibleFrame` 内。
  - 固定为浮窗：顶栏的「固定」按钮会结束 session，把面板改为可拖动的浮窗（`isMovableByWindowBackground`，`level = .floating`），并显示关闭按钮。浮窗和锚定面板共用同一个 `NSPanel` 实例。
  - 内容（SwiftUI `PanelRootView`）：
    - 顶栏：玻璃按钮（`.buttonStyle(.glass)`），左侧「活动监视器」，中间标题，右侧依次为固定、设置、退出。
    - 下方用 `.pickerStyle(.tabs)` 做模块切换，M0 只有 CPU 一个 tab，但结构要按多 tab 写。
    - CPU tab：大号总占用，一张最近 2 分钟的折线图（Swift Charts，读环形缓冲），每核占用的小柱状图（不区分核类型）。
    - 图表和数值层用标准材质或不透明底，玻璃只用在控件层。
  - 需求：面板可见期间注册「面板」需求（`cpu.load` 1 s），隐藏时注销。
  - Debug 启动参数：`--open-panel` 不经 session 直接显示面板（用于截图和开销测量），`--open-settings` 直接打开设置窗口。
- **设置窗口**（D25 的侧栏结构）：
  - 优先用 `NSHostingSceneRepresentation` 把 SwiftUI `Settings` 场景挂到 AppKit 生命周期上；如果 SDK 用法不合适，退回 `NSWindow` + `NSHostingController`，并在偏离记录里说明。
  - 窗口打开期间 `NSApp.setActivationPolicy(.regular)` 并激活，关闭后切回 `.accessory`。
  - 侧栏依次为通用、菜单栏、CPU、历史与导出（占位）、诊断、关于。
    - 通用：全局默认间隔、自动降频开关。
    - 菜单栏：CPU item 开关；另有一行提示：item 过多时可能被收进系统溢出区，可以到「系统设置 → 菜单栏」查看。
    - CPU：间隔覆盖；高开销选项要带开销提示（D19），M0 还没有这类选项。
    - 诊断：见下条。
    - 关于：版本号、build 号；Debug 版另显示 git 短哈希。
- **诊断页**（K19）：
  - 采集器表：每个采集器的状态、数据路径、自检结果，以及最近一次和平均耗时（墙钟与 CPU）。
  - 调度器状态：tick 数、有效需求列表、降频因子与原因。
  - app 自身：CPU 占用（按单核的比例，1 分钟均值）和内存 footprint。
- **日志**（K29）：`Logger(subsystem: Bundle.main.bundleIdentifier!, category: …)`。热路径只打 debug 级别的日志，并且限速；序列号、MAC、IP 这类标识一律用 `.private`。
- **文案**：全部放进 `Localizable.xcstrings`，源语言为 zh-Hans。菜单栏小标签用英文缩写（`CPU`）。

## 7. 命令行（sysinfo-cli）

- `sysinfo-cli selftest`：运行所有采集器的自检并打印结果。
- `sysinfo-cli cpu [--interval 1] [--count 5] [--json]`：逐次打印总占用和每核占用（直接用采集器，不经调度器）。
- 用途：跨机对照（D25）。在 Mac Studio 上，把 `Packages/SysKit` rsync 到远端的 `/tmp/sysinfo-remote/` 后执行 `swift run -c release sysinfo-cli …`；远端只在 `/tmp` 下写文件。

## 8. 测试（K25，Swift Testing）

- 纯函数单测：
  - tick 差分，含计数器回退按复位处理、陈旧判定；
  - 到期计算（多个需求、整数倍间隔、降频因子、暂停）；
  - rusage 时间单位换算；
  - 百分比格式化（K24）。
- 硬件测试打 `.hardware` 标签：`host_processor_info` 读数的核数等于 `hw.logicalcpu`，并且两次读数单调不减；`proc_pid_rusage` 可读。
- UI 不做快照测试。

## 9. Makefile 与脚本（K30、K26）

- `build`：`xcodebuild -project SysInfo.xcodeproj -scheme SysInfo -configuration Debug -derivedDataPath build/DerivedData CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)`
- `run`：先 build，再打开 Debug 版 app（先结束已在运行的 Debug 实例：只结束 SysInfo Dev，不碰其他进程）。
- `test`：`swift test --package-path Packages/SysKit`，默认跳过 `.hardware` 标签；`make test-hw` 包含硬件测试。
- `cli`：构建并运行 `sysinfo-cli`。`remote-cli`：在 Mac Studio 上构建并运行（见 §7）。
- `release`：用 Release 配置构建。
- `measure`：执行 `scripts/measure-overhead.sh`。
- `install`、`notarize`：M0 不实现（K50 待定；notarize 按 D20 为可选）。

`scripts/measure-overhead.sh`（M0 版）：
- 如果 `pgrep -x Stats` 有结果，直接拒绝执行，并提示用户手动退出 Stats（D18、K26）。
- 用 Release 构建启动 app，两档各测一次：
  - 出厂默认配置：1 个 CPU item，面板关闭；
  - 面板打开：带 `--open-panel` 启动。
- 每档先预热 30 s，再测 120 s。用 `ps -o time=` 的差值（或 `proc_pid_rusage`）算出 app 的 CPU 占用（按单核的比例），另记录 MenuBarAgent 和 WindowServer 在同一时段的 CPU 增量，作为软指标。
- 结果（日期、git 哈希、机器型号、各档数值）追加到 `docs/perf/m0.md`。
- 改用 coalition 口径的度量，等 CPU 模块建好私有层之后再做。

## 10. 偏离记录

（实现过程中偏离本文档的地方记在这里：日期、内容、原因。）

- **2026-09-28 · §2「CSysPrivate 不做成 product，app 在编译期就 import 不到它」不成立，改为构建期检查**
  - 实测：Xcode 27 会把依赖闭包里所有 C target 的 module map 传给下游编译（app 的 swiftc 带 `-fmodule-map-file=…/GeneratedModuleMaps/CSysPrivate.modulemap` 和 `-I …/CSysPrivate/include`），所以 app 里 `import CSysPrivate` 能编译通过。SwiftPM 同样如此：`sysinfo-cli` 经 `SysCollectors` 也能 import 到它；`SysModel` 不在闭包里，编译器会拒绝。
  - 试过用 clang module map 的 `requires` 自定义特性（只给 `SysCollectors` 传 `-fmodule-feature`）从编译器层面拦截，但 `SysCollectors` 不开 library evolution，它的 `internal import` 仍要求下游加载 `CSysPrivate`，结果 `sysinfo-cli` 的依赖扫描直接失败，放弃。
  - 现做法：
    - `SysCollectors` 用 `internal import CSysPrivate`，不在公开接口里暴露它；
    - `scripts/check-private-imports.sh` 检查给定目录下的 Swift/C/ObjC 源码有没有 import 或 include `CSysPrivate`，读取失败按失败处理；
    - app target 的第一个构建阶段「Check private imports」对 `App/` 运行该脚本，命中即构建失败（Xcode 与 `make build` 都生效）；
    - `make test`、`make test-hw`、`make cli` 先对 `App/` 和 `Sources/sysinfo-cli` 运行该脚本。
  - 连带：app target 设 `ENABLE_USER_SCRIPT_SANDBOXING = NO`。用户脚本沙盒不允许读取「目录输入」下的文件，而源码列表随同步文件夹变化，没法逐个声明；该阶段只读源码、不写文件。
- **2026-09-28 · §3 补充：Release 不注入 get-task-allow**
  - `xcodebuild build` 默认把 Release 也当开发构建注入 `com.apple.security.get-task-allow`，而公证会拒绝带它的产物（D20）。`Release.xcconfig` 设 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`；Debug 仍保留。
- **2026-09-28 · §8、§9 补充：硬件测试用「标签 + 环境变量」跳过**
  - `swift test` 只能按测试名的正则过滤，不能按 Swift Testing 标签跳过。硬件测试同时带 `.tags(.hardware)` 和 `.enabled(if: SYSINFO_HW_TESTS == "1")`，直接执行 `swift test` 时也默认跳过；`make test-hw` 设置该变量。
- **2026-09-28 · §9 补充：`make run` 按可执行文件路径结束旧实例**
  - `scripts/stop-dev.sh` 只结束可执行文件路径正好是本仓库 Debug 产物（`build/DerivedData/Build/Products/Debug/SysInfo.app`）的进程，比「按 Bundle ID 结束 SysInfo Dev」更窄：从 Xcode 或其他位置启动的实例也不碰（D18）。先发 SIGTERM，5 秒未退出才发 SIGKILL；app 把 SIGTERM 转成 `NSApp.terminate`，正常走退出流程。
  - 另加 `stop`、`check-private-imports`、`clean`、`help` 目标；`install`、`notarize` 只打印「M0 不实现」并返回失败。
- **2026-09-28 · §5.1 采集器协议：要求 `Sendable`，并加 `resetBaseline()`**
  - 协议改为 `Collector: AnyObject, Sendable`，实现用 `Mutex` 保护内部状态。原因：app 在 MainActor 上创建采集器再交给引擎，`sysinfo-cli` 也直接在自己的线程上调用；串行使用时锁没有竞争。
  - 加 `resetBaseline()`：采集器从「无需求」变为「有需求」（含暂停后恢复）时由引擎调用，避免第一个样本变成整段空闲期的平均值。
- **2026-09-28 · §5.1 SelfUsageCollector 的单位自检与回退**
  - 自检用公开的 `getrusage(RUSAGE_SELF)` 交叉校验 `ri_user_time + ri_system_time` 的单位：按 `mach_timebase_info` 换算后吻合即按 mach tick 使用；原始值直接吻合（内核改成真纳秒）则按纳秒使用；都对不上时 CPU 回退到 `getrusage`（状态 degraded），footprint 照常读。这是 D05「先回退到公开路径」的落实，文档原文只写了换算。
- **2026-09-28 · §5.2 定时器：一次性定时源 + 只在有采集器到期的整秒唤醒**
  - tick 网格固定为「Unix 整秒 + 50 ms」，tick 序号即 Unix 秒数；间隔为 k 的采集器在序号为 k 的倍数时到期，相同间隔的采集器天然合并在同一次唤醒里。
  - `DispatchSourceTimer` 用一次性（`repeating: .never`）排定，每个 tick 结束后排到「下一个有采集器到期的 tick」，leeway 100 ms。所有间隔都是 5 s 时，中间 4 个整秒不唤醒，比「每个基础 tick 都唤醒再判断」更省。
  - 「挂起定时器」实现为取消定时源、有需求时再新建，不用 `suspend()`/`resume()`：取消后的定时源保证不会再投递事件，也不用配平挂起计数。
  - `SamplingEngine` 的执行器就是它的私有串行队列（`DispatchSerialQueue`），定时器挂在同一队列上，回调用 `assumeIsolated` 直接在 actor 隔离域里同步跑完整个 tick，不经 Task 跳转。
  - 刚获得需求的采集器在下一个 tick 立即跑一次以建立差分基线（不等整倍数），之后按网格对齐。
  - 同一个 tick 内所有采集器共用一个 `SampleTime`，方便历史与图表按 tick 对齐。
- **2026-09-28 · §5.2 交付：`events()` 同时推送状态变化**
  - 订阅接口是 `events() -> AsyncStream<EngineEvent>`：`.tick(TickResult)` 每个 tick 一次；另有 `.status(EngineStatus)`，在订阅时、需求或降频变化、自检后推送，这样定时器停掉之后诊断页也能看到需求列表和降频状态的变化。每个订阅者只缓存最新 16 个事件。
  - 降频接口为 `setThrottle(factor: ThrottleFactor, reasons: Set<ThrottleReason>)`，`ThrottleFactor` 取 `.normal`、`.slowed(n)`、`.paused`。
- **2026-09-28 · K19 运行中复检的落点**
  - 引擎在某个采集器连续 10 次输出 `unavailable` 后自动重新自检；复检后仍不可用时门槛翻倍（最多 64 倍，1 Hz 下约 10 分钟一次），恢复后回到初始值，避免长期故障时反复自检、刷日志。采集器首次获得需求时如果还没自检过，先自检。启动、唤醒、系统 build 号变化这三个时机由 app 层调用 `runSelfTests()`。
- **2026-09-28 · §7 命令行补充**
  - `selftest` 另支持 `--json`；`cpu --json` 输出 JSON Lines（每次一行）；`cpu` 按绝对截止时间休眠，读数陈旧或核数变化的那一次不计入 `--count`。
  - 新增 `engine [--demand 3] [--idle 3]`：经 `SamplingEngine` 采样，注销需求后检查 tick 计数不再增长、定时器已停（验收第 5 条的命令行验证）。
- **2026-09-28 · §9 `remote-cli` 补充**
  - `REMOTE_HOST` 可在命令行覆盖；ssh 与 rsync 用 `BatchMode=yes`、`ConnectTimeout=10`，密钥登录失败时直接报错；先跑私有 import 检查。
- **2026-09-29 · §5.3 降频信号的汇总规则与开关范围**
  - 汇总写成纯函数 `ThrottlePolicy.evaluate`（SysCollectors，有单测）：锁屏或显示器睡眠 → `paused`；低电量、`thermalState ≥ .serious`、UPS/电池供电（去抖 5 s）、诊断页手动开关 → `slowed(2)`；否则 `normal`。
  - 设置里的「自动降频」关掉后忽略全部自动信号（含锁屏、显示器睡眠的暂停），只保留诊断页的手动开关。理由：D19「由用户主导」，关掉就是完全不自动调节；信号变化仍照常写日志。
  - `systemPrefersReducedResourceUsage` 只是 SwiftUI 环境值，M0 没有接（本节原文允许），日志里也暂不记录它。
  - 唤醒（`NSWorkspace.didWakeNotification`）时让引擎重新自检；系统 build 号记在 `.dev` 域的 `diagnostics.lastSystemBuild`，变化时写日志（启动自检已覆盖复检）。
- **2026-09-29 · §6 设置项的键名与 `--factory-defaults`**
  - 键名：`general.interval`（1/2/5）、`general.autoThrottle`、`cpu.interval`（0 = 跟随全局）、`menubar.cpu.visible`。可以用 `defaults write zone.lyl.sysinfo.dev <键> …` 修改，重启后生效。
  - 新增启动参数 `--factory-defaults`：不读写偏好，只用出厂默认值，供开销测量使用。`--open-panel`、`--open-settings` 在 Release 构建里同样可用（§9 的测量要用 Release 构建）。
- **2026-09-29 · §6 MetricStore 与菜单栏数字**
  - 环形缓冲写成 SysModel 的 `TimeSeries`（按单调时钟保留 15 分钟，均摊 O(1)，有单测）；诊断页的「1 分钟均值」也从它算。
  - 菜单栏数字按 K24 做 EMA 平滑（τ = 1.5 s，按实际时间差加权；不可用时清空，间隔超过 10τ 时不混合旧值），面板图表用原始值。本节原文没写，按 D24 采纳的 K24 补上。
  - 调度状态变化写 info 日志：「采样定时器已排定 / 已停止」「有效需求：…」，用于核对验收第 5 条。
- **2026-09-29 · §6 菜单栏 item 的绘制**
  - 固定宽度按「CPU」（10 pt 半粗）+「100%」（13 pt 等宽数字）算出，本机为 64 pt；数字右对齐，位数变化时不左右跳。
  - session 期间 item 的高亮由系统绘制（27 实测，自绘 `view` 也有），所以不再自绘高亮。
  - 实测：自绘 `statusItem.view` 与 `expandedInterfaceDelegate` 可以一起用，真实点击会开启 session（探针只验证过 `button` 路径）。
  - 实测：按住 ⌘ 把 item 拖出菜单栏后，KVO 收到 `isVisible = false`，设置开关随之关闭、需求注销、定时器停止；在设置里重新打开后，item 以 `isVisible = true` 重新创建并显示（系统保存的「不可见」被 app 设置覆盖，K32）。
- **2026-09-29 · §6 面板的开关细节**
  - 「再次点击 item」：点击交给系统处理，本进程只能从全局鼠标监视器看到。开启 session 的那次点击也会在 didBegin 之后送到全局监视器，所以用 `NSEvent.timestamp` 与面板显示时刻比较，忽略更早的事件。实测再次点击后系统不会重新开启 session。
  - 本 app 其他窗口（设置窗口）里的鼠标按下也算「点别处」（本地监视器）。
  - 面板是可以成为 key 的 non-activating panel：Esc 靠它成为 key window 后由本地键盘监视器处理，不激活 app。
  - `--open-panel`：启动初期菜单栏窗口还在原点，最多等 2 s，等锚点落到菜单栏上再显示；没有 item 时贴屏幕右上角。
  - 面板隐藏时拆掉 `NSHostingView`（同一个 `NSPanel`、`NSGlassEffectView` 复用），关闭后 SwiftUI 不再随每个 tick 重算。
  - 固定为浮窗：`isMovableByWindowBackground` 对 SwiftUI 内容不起作用，另给顶栏加 `WindowDragGesture`（只在固定时启用）。关闭按钮是顶栏左侧的玻璃按钮（xmark），不是标题栏按钮；Esc 同样关闭浮窗；固定期间再点击 item 会回到锚定状态。
  - 顶栏标题放在左右按钮之间的剩余空间居中（左 1 个按钮、右 3 个按钮，严格居中会与按钮重叠）；按钮用 `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)`。
- **2026-09-29 · §6 设置窗口**
  - `NSHostingSceneRepresentation` + `Settings` 场景可用，打开用它的 `environment.openSettings()`，不需要退回 `NSWindow`。窗口通过内容里的 `NSViewRepresentable` 取得，监听 `willClose` 切回 `.accessory`。
  - 协作式激活：用户在面板里点「设置」或重新打开 app 时 `NSApp.activate()` 会生效；经命令行 `--open-settings` 启动时别的 app 在前台，激活不生效，这时用 `orderFrontRegardless()` 把窗口放到最前，用户点一下即激活。
  - 窗口关闭后内容换成空视图，不再读 MetricStore。
  - 诊断页可见期间登记 `diagnostics` 需求（`app.self`，1 s），用于显示本进程开销；所以诊断页开着时调度器不会停。验收第 5 条按「设置窗口关闭」的状态核对。
  - 主菜单手工构建（应用、编辑、窗口三个菜单），只在 `.regular` 期间显示。
  - 「关于」页的 git 短哈希来自 Info.plist 的 `SysInfoGitCommit`，由 Makefile 注入（`Config/Info.plist` 与生成的 Info.plist 合并）。
  - `make strings`：xcodebuild 不会把提取的文案写回 `.xcstrings`，用 `xcstringstool sync` 同步。
- **2026-09-29 · §9 measure 脚本**
  - 构建用 Release 配置，但 Bundle ID 改为 `zone.lyl.sysinfo.dev`、显示名 SysInfo Dev，并带 `--factory-defaults` 启动：测的是优化后的代码，又不碰日用版 `zone.lyl.sysinfo` 的 defaults 域（D16、D18）。产物放在 `build/MeasureDerivedData`。
  - 除 Stats 外，已有 SysInfo 实例在运行时也拒绝执行（会干扰 MenuBarAgent/WindowServer 的对照）；只结束脚本自己启动的进程。
  - 另测一段不运行 SysInfo 的基线（`BASELINE=0` 可跳过），MenuBarAgent、WindowServer 的增量对照基线看；app 的 footprint 用 `footprint -p` 读。
  - 面板档：测量期间若有人点了别处或按 Esc，面板会关闭，脚本从日志里发现后把该档标为作废。
