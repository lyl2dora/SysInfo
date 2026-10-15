# SysInfo

SysInfo 是一个从零设计的自用 macOS 27 菜单栏系统监控 app，**不是** Stats 的移植。`~/Documents/stats` 只用作 popover、菜单栏 widget、桌面小组件的样式参考，不作为架构或数据层的模板。

- Release 版 Bundle ID 是 `zone.lyl.sysinfo`。
- Debug 版是 `zone.lyl.sysinfo.dev`，显示名「SysInfo Dev」，不注册登录项。开发和测试时只读写 `.dev` 的 defaults 域和数据目录，不动用户日用版（D16）。
- 目标设备是用户的多台 Apple 芯片 Mac，不只是开发机 M5 Pro（D20）。当前清单见 D28（取代 D25 的清单）：
  - 本机：M5 Pro，6 Super + 12 Performance。
  - 对照机 Mac mini：M4 Pro，10 Performance + 4 Efficiency，可通过 `ssh user@remote-host` 访问，已装 Xcode 27。原来的 Mac Studio（M2 Max）已被替换，不再是目标设备，它的实测只作旁证。
  - 在对照机上构建或运行 CLI 与探针时，同样遵守 D18 的操作边界。每个模块验收时都要附上两台机器的对照结果。
  - 对照机上可以构建并启动 Debug 版 app 做截图自查，用完按 D39 清场。

## 文档（按需分级读取）
- **每次必读**：`docs/decisions.md`，即决策档（D01 起）。要改变一条决策时，追加新条目并标注「取代 Dxx」，不改写旧条目。
- **开始某个里程碑或模块前读**：
  - `docs/planning/2026-09-28-kickoff-decision-points.md`，即启动清单（K01–K53）中触发时机已到的条目；
  - 调研报告 `docs/research/2026-09-28-capability-sdk-audit.md` 的对应章节。这份报告只在 M5 Pro 上实测过，文末的决策注记列出了已被取代的说法。
- **按需查阅**：`research/probes/`，各条数据路径的参考实现。

## 流程
- 与用户交流用简体中文。
- 顺序（D15）：M0 骨架 → CPU → 功耗与散热 → 内存 → 网络 → GPU 与加速器 → 存储 → 应用活动，之后是 P1。
- 每个模块一次做到完整版（D14），完整版包含哪些内容见 D14。
  - 开工前，先和用户讨论该模块的能力边界（含跨芯片、跨机型差异），以及启动清单中触发时机已到的待定项。（K44、K45 已由 D25 确认）
  - 有真实取舍的部分，先写 `docs/design/<模块>.md`。
  - 模块完成后由用户验收。
- 遇到与决策档冲突的情况或新的真实取舍，先停下来问用户，结论追加为新的 D 条目。
- Git（D17）：
  - 每个里程碑或模块开一个分支，分支内可以小步自动提交，并推送到 origin 作备份。
  - 合并回 `main` 前需要用户确认。
  - 提交信息用英文 Conventional Commits。
- 操作边界（D18）：
  - 不用 sudo，不写 SMC，只结束自己派生的进程。
  - 压测不超过 60 s，并事先告知用户。
  - UI 用截图自查；Debug 构建提供 `--open-panel`；真实点击由用户验收。
- 本机可能开着 Stats。做精度对照或开销测量前，先检测它是否在运行；如果在运行，请用户手动退出，measure 脚本拒绝执行。Claude 不自行结束 Stats（D18、K26）。
- 语言约定：标识符用英文，代码注释和文档用中文。

## 产品边界
- 主 app 不开沙盒（Xcode 27 模板默认开启，要关掉）。只支持 arm64，最低 macOS 27.0（D03）。
- root 只用于风扇控制；v1 只读取风扇状态，不为其他功能做 root helper（D04）。
- 菜单栏每个 mini widget 只显示一项指标，一个 widget 一个 item，并提供合并选项（D38 取代 D06 第一条）。面板用统一的 `NSPanel`（D21）。禁用 `MenuBarExtra(isInserted:)`。
- 小组件是预留功能：现在只在数据模型里定义 Codable 快照类型，不加 App Group entitlement（D07、K31）。
- 不做 Remote/SaaS、自动更新器、蓝牙扫描、世界时钟（D13）。
- 默认不引入第三方依赖，例外只有 Apple 官方的 swift-* 包。文案统一放进 String Catalog（D23）。

## 硬性规则
- 私有 API 只能出现在私有 C 层（`CSysPrivate`）及其封装里（D05、D23）。编译器拦不住这条，由构建期检查保证（D26）；不要绕过或弱化 `scripts/check-private-imports.sh`。
- 每个私有数据源、每个随芯片变化的数据源都要实现 `selfTest()`，并按 D05、D20、K19、K17 执行：
  - 复检时机：启动、唤醒、系统 build 号变化、运行中连续越界。
  - 自检失败时，先回退到公开路径；回退不了就显示为不可用。未知芯片同样处理。
  - 「不可用」用显式的数据质量状态表示，不用 0 或 NaN 代替。推断、估算、30 分钟批次类指标要标注数据质量。
- 与芯片、机型相关的一切，都在运行时发现或按芯片档案映射，不写死 M5 Pro 的值（D20）。
  - 核按 `hw.perflevelN` 和 `cluster-id` 分组，不按字母 E/M/P 猜核类型，也不按品牌字符串猜芯片代际。
- 采样不能在 MainActor 上运行（D03、D23）。
- 所有采集器共用一个合并 tick，只在有消费者时采样。
- 出厂默认配置要达到：常驻低于 0.5% 单核，面板打开时低于 2%。用户自己开启的高开销项不受这个限制，但设置里要标注开销（D19）。D19 只放开本进程开销方面的限制，不覆盖 D09、D10。
- 菜单栏 item：自绘 `NSStatusItem.view`，宽度固定，不随数值变化；数字用等宽字体；颜色用模板色或语义色。
- 已知陷阱（节选，完整清单见调研报告 §2.5，实现相关模块前必读）：
  - 网络：
    - 字节计数只用 IFMIB，不用 `NET_RT_IFLIST2`/`getifaddrs`；链路速率不用 `ifi_baudrate`。
    - 计数器出现负差值时按复位处理，不要钳为 0。
  - GPU 利用率不用 `PerformanceStatistics["Device Utilization %"]`。
  - 功耗：
    - IOReport Energy Model 中由 PMGR 驱动的通道（CPU、ANE、DRAM、GPU0 等）每 30 分钟才批量发布一次，不能用作实时功耗。
    - AGX 的 `GPU Energy` 是例外，它是实时的，是 GPU 功耗的首选来源。
    - 实时 CPU、DRAM、SoC 功耗改用 SMC（调研报告 §0-2）。
    - `PowerTelemetryData` 累加器在高负载下会整分钟漏记，长期能耗用 `PDTR` 积分（D46）；CPU 专用轨不乘 PMGR 系数（D45）；M4 的 SMC GPU 轨不是 GPU 功率，GPU 一律用 AGX（D44）。
  - `host_statistics` 受全系统节流：页面计数改读 `vm.page_*` sysctl；与上次逐字节相同的结果视为陈旧。
  - 传感器：
    - SMC 按属性位判断字节序，要支持 `flt`、`ioft`、`si32` 等类型，并检查 result 字节。
    - CPU 温度不能只读 `Tp**`，会漏掉 M 簇。
    - HID 服务不能用 Product 名做字典键，同一个传感器会注册多次。
  - 电源：不要把所有 IOPS 电源都当成电池（UPS、配件不是电池）。
  - 外部命令：
    - nettop 只在面板打开、且对应卡片可见时调用（D09、K18）；CoreWLAN 只在面板打开时读，不轮询（D10）。
    - 不定时 spawn `top` 或 `ps`；`top` 只作为 D05 的回退路径，具体形式待 K38 定。
- 隐私（D10、D22）：
  - 默认不弹授权框，默认不联网。
  - 不申请定位和蓝牙权限，不读 SSID/BSSID，不链接蓝牙框架。
  - 不调用 `system_profiler`。
  - 电源设备的 HID 设备匹配限定在 usage page 0x84，不做宽泛匹配。
- 设备唯一标识（序列号、硬件或卷 UUID、MAC、公网 IP）不进版本库；日志里用 `.private` 输出。

## 构建与测试
入口一律用 Makefile（`make help` 可列出所有目标）：
- 构建与运行：
  - `make build`：构建 Debug 版 SysInfo Dev。
  - `make run`、`make stop`：启动 Debug 版，或结束正在运行的 Debug 实例；只会结束 Debug 实例。`ARGS` 传给 app，例如 `--open-panel`、`--open-settings`、`--factory-defaults`。
  - `make release`：构建 Release 版（`zone.lyl.sysinfo`）。
- 测试：
  - `make test`：跑单元测试，默认跳过硬件测试。
  - `make test-hw`：连硬件测试一起跑（设置 `SYSINFO_HW_TESTS=1`）。
  - 这两个目标都会先跑 `test-scripts` 和 `check-private-imports`。
- 命令行：`make cli ARGS="selftest"`、`make cli ARGS="cpu --count 5"`。
- 对照机（M4 Pro）跨机对照：
  - `make remote-cli ARGS=…`、`make remote-test`。远端只写 `/tmp/sysinfo-remote`。
  - 地址可以用 `REMOTE_HOST=user@host` 覆盖。
- `make measure`：测量自身开销，结果追加到 `docs/perf/`。Stats 或其他 SysInfo 实例在运行时，脚本会拒绝执行。
- `make strings`：把代码里的文案同步进 `App/Localizable.xcstrings`。
- `install`、`notarize` 目前只是占位：K50 待定，notarize 按 D20 为可选。
- 私有层隔离：编译器拦不住 app 或 CLI 去 import `CSysPrivate`。现在靠 `scripts/check-private-imports.sh` 在构建期检查，app 的构建阶段和 `make test`、`make cli` 都会执行（D26）。
- 用合成事件（CGEvent）测 UI 时，修饰键必须成对发送按下和抬起，测完用 `CGEventSource.flagsState(.hidSystemState)` 确认没有残留。不要用 osascript 控制其他 app。
