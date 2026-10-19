# 桌面小组件能力边界（讨论稿）

> 日期：2026-10-19 · 状态：**probe 进行中**（A、C、D 已测完；B、E 进行中） · 分支：`module/widgets`
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

## 5. B：重载预算（进行中）

- B2（dev，19:58 起）：host 每 60 s 调一次 `reloadAllTimelines`。前 50 分钟 chronod 照做 60 次，最长间隔 60 s，**没有限流**；每次都记作 `externalRequest … budgeted`。
- B1（rel，20:48 起）：host 不调用刷新，timeline 用 `.after(5 min)`，看系统自然给多少次。
- B3（待测）：host 切到前台时（chronod 有 `containerApp-ExemptReason`），刷新是否免预算。

## 6. E：开发者模式豁免（待测）

chronod 里有 `widgetKitDeveloperModeEnabled` 与豁免原因 `widgetKitDeveloperMode-and-extensionIsBeingDeveloped`，ChronoKit 里有 `com.apple.security.get-task-allow`。用户已同意本次修改 `com.apple.chronod` 偏好，测完恢复（D87）。测试前该键不存在。
