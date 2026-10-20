# 桌面小组件实现规格

> 日期：2026-10-19 · 状态：**已拍板**（2026-10-19 用户确认 WS1–WS4 全部按推荐，见 D91） · 分支：`module/widgets`
> 能力边界见 `widgets-boundary.md` 与 D90；本文只写怎么做。

## 1. 组成

| 部分 | 位置 | 说明 |
|---|---|---|
| 快照格式 | `SysModel/WidgetSnapshot.swift` | `WidgetSnapshot` 升到 v2（§3），主 app 写、扩展读，两边共用 |
| 快照写入 | `App/Widgets/WidgetSnapshotWriter.swift` | 后台消费者：有组件放置时按节奏采样、写组容器、刷新组件（§4） |
| 刷新 intent | `App/Widgets/RefreshWidgetIntent.swift`（两个 target 都编进去） | `allowedExecutionTargets = .main`，主进程现采一次再刷新（§5） |
| 扩展 | 新 target `SysInfoWidgets`，目录 `Widgets/` | 沙盒；只链接 SysModel（不链接 SysCollectors、SysStore，碰不到私有层）；一个「总览」组件四种尺寸（§6） |
| 设置 | 新侧栏页「桌面小组件」（WS4） | 刷新节奏、已放置的组件、说明（§7） |
| 隐私页 | `SettingsRootView.swift` 的「数据存放」 | 加一行组容器路径（D90 W6） |

## 2. 标识、签名与工程

- 扩展 bundle ID：Release `zone.lyl.sysinfo.widgets`，Debug `zone.lyl.sysinfo.dev.widgets`（D16）。显示名「SysInfo」/「SysInfo Dev」。
- App Group：Release `D8MFB2YNN3.zone.lyl.sysinfo`，Debug `D8MFB2YNN3.zone.lyl.sysinfo.dev`。主 app 与扩展各一份 entitlements（`Config/SysInfo.entitlements`、`Config/SysInfoWidgets.entitlements`），组名用 `$(SYSINFO_APP_GROUP)` 由 xcconfig 给出。主 app **仍不开沙盒**（D03），扩展**必须**开沙盒（probe A）。
- Developer ID 签名下 Team ID 前缀的组不需要描述文件（probe A）。CI 的签名、公证流程（D74）要确认会对嵌入的 `.appex` 一起签名公证；`make dist` 同步检查。
- 工程：`SysInfo.xcodeproj` 加一个 app-extension target，`Widgets/` 作为它的 file-system-synchronized 根组；`App/Widgets/RefreshWidgetIntent.swift` 与快照相关的共用代码通过 target membership 两边都编。扩展的 xcconfig `Config/Widgets.xcconfig`（沿用 Shared 的签名与部署目标，`ENABLE_APP_SANDBOX = YES`，不设 MainActor 默认隔离以外的差异）。
- 私有层隔离（D26）：`scripts/check-private-imports.sh` 的扫描目录加上 `Widgets/`，Makefile 的 `PRIVATE_IMPORT_GUARDED` 与扩展 target 的脚本阶段都要传。
- 文案：扩展用自己的 String Catalog `Widgets/Localizable.xcstrings`，`make strings` 一并同步（D23）。
- 同一 bundle ID 只能有一份被登记（probe A）：Debug 只从 `build/DerivedData` 运行，不另外拷贝。

## 3. 快照格式（v2）

```swift
struct WidgetSnapshot: Codable {
    static let currentVersion = 2
    var version: Int
    var generatedAt: Date
    var appRunning: Bool              // 写入方是否在跑（正常退出时写一份 false，§6.4）
    var refreshInterval: TimeInterval // 当前节奏，扩展据此判断陈旧
    var items: [Item]                 // 按 WS1 的固定顺序
    struct Item: Codable {
        var metric: MetricID
        var sample: Sample            // 值 + 数据质量（D24），不可用时 value 为 nil
        var curve: [CurvePoint]?      // 只有大号以上用到的项才带：最近 24 h，每 5 分钟一个点（≤ 288 点）
    }
    struct CurvePoint: Codable { var minute: Int64; var avg: Double }
}
```

- 一份快照约 10–20 KB（6 项、其中 4 项带 288 点），读取 < 1 ms（probe D：25 KB 约 0.3–0.9 ms）。
- 不放设备唯一标识（D22）。盘温取「启动盘所在的盘」，快照里只放数值，不放盘的标识。
- 文件：组容器根目录下 `widget-snapshot.json`，原子写入。v1 只定义过类型，从没写出过，直接升 v2，不做迁移。

## 4. 快照写入（主进程）

### 4.1 什么时候写

- 只在有组件放置时写（D90 W2）。`WidgetCenter.shared.currentConfigurations()` 判断：启动时查一次，之后每 5 分钟查一次（XPC 一次，开销待 §8 实测）；数量从 0 变正时立刻写一份并刷新。
- 扩展被拉起但快照缺失或太旧时，扩展往组容器写一个 `widget-wanted` 标记（时间戳）；主进程查配置时顺便看这个文件，有新标记就立刻写，免得刚放上组件要等最多 5 分钟。
- 没有组件放置时：撤掉需求，不采样、不写文件（D12「只在有消费者时采样」）。

### 4.2 采样

- `DemandSlot` 登记一个后台需求：`Demand(collectors: [CPU 占用, 内存, 整机功率, SoC 热点, 盘温, 网速], interval: 300 或 60, source: "widget", tier: .background)`。历史记录开着时这些采集器本来就以 10–60 s 在跑，这条需求基本不增加采样，只保证历史关闭时也有数据。
- 用 `.background` 档：锁屏 / 显示器睡眠时仍按节奏写（chronod 在这期间是否刷新组件见边界文档 §5 待测；写入本身很便宜）。
- 当前值取 `MetricStore.latest`；`latest` 里某项比节奏还旧时按陈旧处理，写成不可用（`staleSample`），不拿旧值冒充。

### 4.3 曲线

- 从 `HistoryRecorder.series(metric, from: now − 24 h, to: now, granularity: .minute, bucketMinutes: 5)` 读，每次写快照时读一次（4 项 × 288 点，SQLite 本地读取，毫秒级，§8 实测）。
- 历史记录关闭或该模块的历史关闭时：曲线只放内存环形缓冲里的最近 15 分钟，组件上注明「历史记录已关闭」。

### 4.4 写完刷新

- 写完调 `WidgetCenter.shared.reloadTimelines(ofKind: "overview")`。probe B：主进程每分钟主动刷新连续两小时都被照做；5 分钟节奏下余量更大。
- 扩展的 timeline 不自己请求频繁刷新：`policy: .after(now + 节奏 × 3)`，只作为主进程没刷新时的兜底。

## 5. 点击刷新

- `RefreshWidgetIntent: AppIntent`，`allowedExecutionTargets = .main`（macOS 27）。chronod 找到正在运行的主进程直接连接，不拉到前台（probe C）。
- `perform()`：让写入器加一个 1 s 的临时需求，等到下一个 tick 有新样本（最多 2 s）后写快照、撤掉临时需求，再 `reloadTimelines`。刷新由 `interaction` 触发，不计预算（probe C）。
- 主进程没在运行时 intent 会怎样未测（边界文档 §3）。实现时补测；如果系统会拉起主进程，按正常启动处理（开机自启没开的用户也能点）。

## 6. 扩展与组件

### 6.1 组件

一个 kind `overview`，`StaticConfiguration`，支持 `.systemSmall`、`.systemMedium`、`.systemLarge`、`.systemExtraLargePortrait`（WS2：v1 不做组件内选指标）。内容按 WS1。

### 6.2 显示规则

- 数值格式与菜单栏、面板一致（复用 SysModel 的格式化；菜单栏专用的格式化在 App 里的，挪进 SysModel 共用）。
- 数据质量：不可用显示「—」；估算 / 推断类加角标（与面板一致，D24）。
- 渲染模式：桌面上是 `accented`（probe A）。关键数值与曲线 `widgetAccentable`；不靠色相区分高低。`fullColor` 下沿用面板的语义色。
- 生成时间用 `Text(generatedAt, style: .relative)`，系统自己走字，不需要刷新。

### 6.3 陈旧与未运行

- 快照年龄超过节奏 × 3，或 `appRunning == false`：数值变暗，底部显示「SysInfo 未运行 · <相对时间>」，刷新按钮仍可点（WS3）。
- 没有快照（从没写过）：显示「打开 SysInfo 后显示数据」，并写 `widget-wanted` 标记。

### 6.4 主进程退出

- 正常退出时写一份 `appRunning = false` 的快照并刷新一次，组件马上显示「未运行」，不用等陈旧判断。

## 7. 设置页「桌面小组件」

- 刷新节奏：每 5 分钟（默认）/ 每 1 分钟，后者标注开销（D19，数值取 §8 实测）。
- 状态：已放置的组件数（尺寸列表），最近一次写入时间。
- 说明：组件怎么放（桌面右键「编辑小组件」），数据只在本机组容器里。
- 隐私页「数据存放」加一行组容器路径。

## 8. 验证与开销

- 单元测试：快照 v2 编解码、陈旧判断、曲线降采样（SysModelTests）；写入器的「有无放置 → 需求」逻辑做成纯类型测。
- 开销（`make measure` 加一档「已放置组件」）：主进程写入（5 min / 1 min）、`currentConfigurations` 轮询、扩展进程每轮渲染的 CPU。出厂默认没有组件放置，应与不做小组件时相同。
- 两台机器：本机放全部四种尺寸；M4 上需要用户放一个（屏幕共享），验证扩展侧。
- 验收：放置、删除、主进程退出与重启、锁屏后解锁、点击刷新、历史关闭时的曲线降级、Debug 与 Release 并存。

## 9. 待拍板（WS1–WS4）

- **WS1 各尺寸放什么**（推荐）：
  - 小：CPU 占用、内存占用（两个大数字）；
  - 中：CPU 占用、内存占用、整机功率、SoC 热点温度；
  - 大：中号四项 + 网速上下行，加 CPU 占用与整机功率的 24 h 曲线；
  - 超大竖版：大号全部 + 内存与 SoC 热点的 24 h 曲线、启动盘盘温。
- **WS2 组件里能不能自选指标**：推荐 v1 不做（固定内容，`StaticConfiguration`）；以后需要再改成 `AppIntentConfiguration`。
- **WS3 SysInfo 没在运行时**：推荐保留最后的数据并变暗，注明「未运行」与时间（§6.3），不清空。
- **WS4 设置放哪儿**：推荐新开侧栏页「桌面小组件」（放在「历史与导出」前面）；不并进「通用」。

## 10. 进度（2026-10-21）

- 已完成（`module/widgets`，未合并）：扩展 `SysInfoWidgets`、快照 v2、写入器、刷新 intent、设置页「桌面小组件」、隐私页一行、构建与发布检查。本机 M5 验证过：四种尺寸的渲染（fullColor 与 accented）、放置后 12 s 内出数据、点击刷新在主进程执行且不计预算、退出后显示「未运行」、重启后恢复。
- 开销：扩展约 0.1% 单核（5 分钟）/ 0.4%（1 分钟），见 `docs/perf/widgets.md`。出厂与面板两档 2026-10-20 在 M4 复测通过（0.095% / 0.412%，与 1.0.0 相当）；M5 那次受后台干扰，不作结论。
- probe B 的 24 h 结论：没有每日上限（边界文档 §5）。probe 已停掉、注销。
- 待办：
  1. ~~M4 复测出厂默认与面板两档~~（2026-10-20 完成，通过）。
  2. ~~M4 上扩展侧验证~~（2026-10-20 完成，见 §11）。
  3. ~~用户手动删掉桌面上两个探针小组件（SysInfo Probe Dev / Rel）~~（2026-10-21 用户已删）。本机两个探针的组容器还在（受 TCC 保护，没从终端删）。
  4. ~~写 `docs/design/widgets-acceptance.md`~~（2026-10-21 完成）；用户验收后合并回 `main`。
- 2026-10-21 合入 `main` 的 D93（SMART 重试）。
- 菜单栏拖拽排序已在 `main` 完成（D92），2026-10-20 合入本分支。

## 11. M4 扩展侧验证（2026-10-20）

本机 Developer ID 签名的 Debug 构建（2a4e306）拷到 M4，带 `--factory-defaults` 运行，用户屏幕共享放了小 / 中 / 大 / 超大竖版各一个。

- 通过：
  - App Group 可用，放置后不到 30 s 出数据；四种尺寸的内容与 D91 一致，读数与菜单栏一致。
  - 5 分钟节奏的刷新照常到达。
  - 点击刷新：在主进程执行（chronod「Successfully ran action」），约 0.3 s 内四个组件一起换成新快照。
  - 正常退出后变暗，显示「SysInfo 未运行 · 时长」（小号「未运行 ·」）。
- 发现：
  1. **app 放在 `/tmp` 下时刷新按钮无效**。linkd 给 App Intents 建索引时找不到这个 app 的记录（-10814），chronod 报「There is no metadata for RefreshWidgetIntent」；`lsregister -f` 重登记也一样。同一份构建拷到 `~/Applications` 后 linkd 正常收录两份 `Metadata.appintents`，按钮可用。正式版装在 `/Applications` 不受影响；从「下载」直接打开、被 App Translocation 挪到临时路径运行的情况可能同样受影响，未验证。`remote-app.sh` 在 `/tmp` 下运行，测刷新按钮时要换位置。
  2. **启动盘温度偶尔是「—」**：起初以为是首份快照写得太早，加了补写后实测并非如此。真正原因是同时开着 Release 与 Dev 时两个实例每秒同一时刻抢独占的 SMART 连接，Dev 菜单栏的盘温也会闪空；与小组件无关，main 上就有。已在 `fix/smart-busy-retry` 修复（D93），补写逻辑撤掉未提交。
  3. **曲线头 5–10 分钟显示「暂无数据」**：历史曲线按 5 分钟分桶，少于两个桶时不画；`--factory-defaults` 用临时历史库，每次启动都从空开始。属预期，验收时注意。
  4. **一次被系统重新拉起**：23:31 结束 `/tmp` 下的实例后，launchd 以「launch job demand」立即重新拉起了它（不带 `--factory-defaults`，读写真实的 Dev 偏好域），触发方未查明；之后两次结束都没有复现。待观察，如果复现要查是不是 App Intents 的连接导致。
  5. 清场缺口：扩展的沙盒容器 `~/Library/Containers/<app>.widgets`（以及 `.measure.widgets`、`.probe.widgets`）不在 `remote-app.sh` 的痕迹清单里，M4 上这三个都是之前留下的，这次没删。

