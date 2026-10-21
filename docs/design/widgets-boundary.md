# 桌面小组件能力边界（讨论稿）

> 日期：2026-10-19 · 状态：**已拍板**（2026-10-19 用户确认 W1–W7 全部按推荐，见 D90）；M4 扩展侧渲染待补测 · 分支：`module/widgets`
> 依据 D87。结论定下来之后，要拍板的问题列在 §6，拍板后追加为新的 D 条目，再另写实现规格。

## 1. 目的与口径

P2 的桌面小组件（D07）开工前的 probe。9-28 的 gap 探针只验证过「不开沙盒会被 pkd 拒绝」，接受的那条路从没走通过；重载节奏只测过 Apple 自己的天气组件。这次用自己的探针把整条链路走一遍。

- 探针在 `research/probes/widgets/`：不开沙盒的 host（LSUIElement，定时往组容器写快照，可选地调用 `reloadAllTimelines`）+ 开沙盒的 WidgetKit 扩展（小 / 中 / 大 / 超大 / 超大竖版，外加一个 Control）。两边共用组容器里的 `snapshot.json`，并往 os_log 写事件。
- 两套标识，对应正式版的 Debug / Release 形态（D16）：
  - dev：`zone.lyl.sysinfo.dev.probe`，扩展 `.widgets`，App Group `D8MFB2YNN3.zone.lyl.sysinfo.dev.probe`；
  - rel：`zone.lyl.sysinfo.probe`，同样的派生方式。
- 两套都用 Developer ID Application 签名、开 Hardened Runtime，不注入 get-task-allow（与正式版 `Shared.xcconfig` 一致）；E 另有一份带 get-task-allow 的扩展。
- 本机 M5 Pro，macOS 27.0.1；对照机 M4 Pro，macOS 27.0.1。

## 2. A：端到端链路

| 项 | M5 Pro | M4 Pro |
|---|---|---|
| pkd 接受沙盒扩展 | 是（两套） | 是（两套） |
| chronod 发现扩展 | 是：`Added extensions`；非 Apple 扩展的描述不缓存（`purging instead because we shouldn't cache it`），与 Stats 相同，不影响使用 | 是，相同 |
| host 访问组容器 | 直接放行，**无弹窗**：`APPROVED. Requestor's signature allows it to access a TCC-protected group container` | 相同 |
| 沙盒扩展读组容器 | 可以（dev 放置后、rel 在图库预览时） | 未测：对照机上没人放组件 |
| 桌面渲染 | 五种尺寸都正常（快照序号、系统自己走字的相对时间、Swift Charts 曲线、按钮） | 未测 |

发现：

- **同一 bundle ID 有两份时只认一份**。xcodebuild 产物在 DerivedData，拷出来又一份，pkd 只登记其中之一（9-28 Stats 也是这样）。正式开发时 `build/` 里的 Debug 版和别处的副本不能并存；探针的 build.sh 删掉并注销 DerivedData 里的那份。
- **组容器受 TCC「App 数据」保护**：别的进程（包括终端里的 shell）读它会触发系统的授权请求。只有签名匹配的 app 本身（以及同 Team 的扩展）能直接访问。所以以后排查问题不能从终端直接看组容器，要靠日志或 app 自己导出。
- 桌面组件的渲染模式报的是 `accented`（着色），容器背景开着。正式设计要按 accented 的效果来定，不只靠色相区分，关键元素用 `widgetAccentable`（调研报告 §2.3）。
- 放置后，chronod 会为同一个 kind 的各尺寸各请求一次 timeline（包括没有放的尺寸，图库预览用）。

## 3. C：交互按钮与执行位置

用户在桌面组件上点了两个按钮（2026-10-19 20:00）：

| 按钮 | 执行位置 | 刷新 | 预算 |
|---|---|---|---|
| `allowedExecutionTargets = .main`（macOS 27） | **host 进程**。chronod：`The intent ProbeRefreshIntent is only allowed in app zone.lyl.sysinfo.dev.probe`，找到已在运行的 host 后直接连接，不调用 `openApplication`，不拉到前台 | 点击后约 0.24 s 组件更新（`interaction`） | **不计**（`interaction-immediate-free`） |
| 默认（不指定） | 扩展进程 | 约 0.2 s | 不计 |

- 含义：正式版可以做「点一下刷新」，由主进程现采一次、写快照，再刷新组件，不扣预算。
- 待测：host **没在运行**时，`.main` 的 intent 会不会把它启动（正式版的主进程通常都在运行，影响不大）。
- Control（控制中心 / 菜单栏控件）探针里有，用户没有放，未测。

## 4. D：渲染与资源

在 dev 的五个组件上逐档改快照参数，每档等一次刷新（`d_sweep.sh`）：

| 档 | 快照大小 | 扩展读 + 解码 | 扩展 footprint | 结果 |
|---|---|---|---|---|
| 60 点 | 1 KB | 0.05–0.2 ms | 11.6 MB | 正常 |
| 1440 点（24 h 的分钟曲线） | 25 KB | 0.3–0.9 ms | 12 MB | 正常，曲线清晰 |
| + 1 MB 填充 | 1 MB | 0.9–2.6 ms | 12 MB | 正常 |
| + 10 MB 填充 | 10 MB | 14–18 ms | 22 MB | 正常 |
| 额外分配 30 / 60 / 120 / 250 MB | 25 KB | — | 36 / 61 / 117 / 242 MB | **都正常，没有被杀** |

- 桌面扩展的内存上限至少在 250 MB 以上，比 iOS 宽得多；快照大小也不是瓶颈。真正的约束是刷新次数（B）。
- 20:02 扩展进程被 SIGKILL 一次（同一时刻 chronod 有 AppIntents 连接报错 `LNConnectionErrorDomain 1004/1005`），原因未明；之后 chronod 照常重新拉起，组件不受影响。

## 5. B：重载预算

本机 M5（Mac mini，一直接着电源，桌面组件可见），用 `b_analyze.py` 从 chronod 日志统计：

| 段 | 做法 | 窗口 | chronod 实际执行 | 预算记账 |
|---|---|---|---|---|
| B2（dev，5 个组件） | host 每 60 s 调一次 `reloadAllTimelines` | 19:58–21:48（110 min） | 每个 kind **119 次**，最长间隔 60 s，**没有限流** | 每次 `externalRequest … budgeted`，没有被拒 |
| B1（rel，1 个小组件） | 不主动刷新，timeline 用 `.after(5 min)` | 20:48–21:48（60 min） | **13 次**，约每 5 min 一次，最长间隔 320 s | `timelineExhausted … budgeted` |

- 9-28 的「放置后 30–45 分钟才重载一次」是系统天气组件**自己**排的节奏，不是第三方组件的上限。第三方组件请求 5 分钟就给 5 分钟，主 app 每分钟主动刷新也照做。
- 「计预算」与「被限流」是两回事：每分钟一次的刷新都记了账，但没有一次被拒。

**24 h 复测（2026-10-19 19:58 → 10-20 20:02，同一份 chronod 日志）：**

| 段 | 实际执行 | 每小时 | 最长间隔 | 被限流 |
|---|---|---|---|---|
| B2（dev，主进程每 60 s 主动刷新） | **1453 次** | 每小时 60 次，夜里也一样 | 60 s | 无 |
| B1（rel，只靠 `.after(5 min)`，21:53 起） | 251 次（22 h） | 11–12 次 | 321 s | 无 |

- 24 h 内**没有出现每日上限**。日志里 3449 条「Ignoring」全是 NotificationCenter 的「Ignoring staleness check - not visibly settled for current view session yet」，与预算无关。
- 结论：D90 W2 的「1 分钟」档不需要额外加次数限制；代价只在开销（扩展约 0.4% 单核，`docs/perf/widgets.md`）。
- 没测到的：本机显示器设为永不睡眠（`displaysleep 0`），这 24 h 里没有显示器睡眠或锁屏的时段，chronod 在那种情况下是否继续刷新不知道。带电池的机型由电池供电时预算是否收紧也没测（目标设备里暂时没有）。
- B3（host 在前台时 `containerApp` 豁免）：只有预算会被用完时才有意义，等 B2 撞上上限再测。

## 6. E：开发者模式豁免（K53）

chronod 里有 `widgetKitDeveloperModeEnabled` 与豁免原因 `widgetKitDeveloperMode-and-extensionIsBeingDeveloped`，ChronoKit 里有 `com.apple.security.get-task-allow`。用户同意本次修改 `com.apple.chronod` 偏好、测完恢复（D87）。

- 21:49 给 rel 换上带 get-task-allow 的扩展（`build.sh reldevmode`），host 每 60 s 主动刷新；21:49:46 写入 `widgetKitDeveloperModeEnabled = YES`（修改前该键不存在）。
- 之后 3 分钟里每次刷新仍是 `externalRequest … budgeted` / `timelineExhausted … budgeted`，日志里**没有** `Ignoring budget … due to widgetKitDeveloperModeEnabled`。
- 可能原因：chronod 只在启动时读这个偏好；或「extensionIsBeingDeveloped」要求扩展由 Xcode 调试启动。chronod 是系统进程，按 D18 不结束、不重启它，到此为止。
- 21:52:58 已恢复：删除该键，复查为「不存在」，与修改前一致。rel 随后换回不带 get-task-allow 的普通构建。
- 结论：这条路在不重启 chronod 的前提下不生效；而 B 显示第三方组件的刷新本来就没被限流，**豁免没有必要**。建议 K53 关闭：不做开发者模式豁免。

## 7. 开销（扩展进程）

| 扩展 | 组件 | 刷新 | 运行 | 累计 CPU | 平均 |
|---|---|---|---|---|---|
| dev | 小、中、大、超大、超大竖版（含 Swift Charts 曲线） | 每 60 s（host 主动） | 99 min | 20.7 s | 约 0.35% 单核；每轮约 0.2 s，每个组件约 40 ms |
| rel | 1 个小组件 | 每 5 min（timeline） | 65 min | 0.83 s | 约 0.02% 单核 |

- 这是原始 CPU 时间（`ps`），没有按 D80 折算；chronod 与 NotificationCenter 的渲染开销没算进来。
- 扩展是独立进程，D19 / D80 的预算原本只约束主进程。但「每分钟刷新」只算扩展就已经和主进程常驻预算（0.2%）同一量级，刷新节奏要当作开销项来定。

## 8. 待拍板（W1–W7）

- **W1 做哪些组件**：推荐一个「总览」组件，支持小 / 中 / 大 / 超大竖版，内容按尺寸递增（小：一两项核心数值；中：四项；大与超大竖版：加 24 h 分钟曲线）。不做每个模块各一个组件（数量多、用户要逐个放）。
- **W2 刷新节奏**：推荐出厂每 5 分钟（timeline `.after`，扩展开销约为每分钟刷新的 1/5，且不需要主进程主动刷新），设置里可选 1 分钟并标注开销（D19）。主进程只在有组件放置时（`currentConfigurations` 非空）才写快照。
- **W3 点击刷新**：推荐做。组件上放一个刷新按钮，intent 指定在主进程执行（`.main`），现采一次再刷新，不计预算（C）。
- **W4 Control（控制中心 / 菜单栏控件）**：probe 里有，没有测。推荐这次不做，等组件做完再定。
- **W5 快照内容**：每个指标的当前值与数据质量状态（D24），加最近 24 h 的分钟曲线（1440 点约 25 KB，读取 < 1 ms，D）。快照里不放设备唯一标识（D22）。
- **W6 App Group 与隐私**：主 app 与扩展加 Team ID 前缀的 App Group（Release `D8MFB2YNN3.zone.lyl.sysinfo`、Debug `…sysinfo.dev`），落实 K31；隐私页的「数据存放位置」补上组容器。组容器受 TCC「App 数据」保护，只有本 app 与扩展能读。
- **W7 K53**：关闭，不做开发者模式豁免（§6）。
