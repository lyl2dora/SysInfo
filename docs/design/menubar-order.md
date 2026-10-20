# 菜单栏 widget 排序（开工前的说明）

> 日期：2026-10-20 · 状态：**probe 完成，待用户确认做法（§6.3）**（2026-10-19 用户提出，要求与小组件模块的开销复测一起做） · 分支：开工时从 `main` 新开，不放进 `module/widgets`
> 开工前按 CLAUDE.md 的流程：先做下面 §3 的 probe，结论与用户确认后记成新的 D 条目。
> **决策编号**：`main` 上的决策档目前到 D89，D87、D90、D91 只在 `module/widgets` 分支上（桌面小组件），排序功能的新条目从 **D92** 起编，免得两个分支合并时撞号。
> 开工时本机 checkout 可能还停在 `module/widgets`：从 `main` 开新分支前，确认工作区干净；需要并行时用独立的 worktree。

## 1. 需求（用户原话）

「设置页的菜单栏顶部加一个排序，自定拖拽决定排序。」（2026-10-19）

## 2. 现状

- 每个 widget 是一个独立的 `NSStatusItem`，各有 `autosaveName`（`App/MenuBar/StatusItemController.swift`，约第 280 行，`"<bundle id>.cpu.<项>"` 一类）。用户按住 ⌘ 拖动后的位置由系统记住。
- app 没有公开 API 在运行时移动 item，也管不了与其他 app 的 item 的先后。
- 没有记住过位置时，**后创建的 item 落在已有 item 的左边**（2026-10-19 D89 实测：电源设备 widget 最后创建，落在最左）。
- 合并模式（D65）里的顺序完全由 app 决定：设置页「菜单栏」的「合并顺序」（`menuBarMergedOrder`）；`StatusItemController.screenOrder()` 能读出各 item 当前在屏幕上从左到右的顺序（D65 MG1 用它定合并的初始顺序）。

## 3. 开工时先做的 probe（本机 M5 与 M4 都测）

1. 系统把位置存在 app 自己的 defaults 里，键名 `NSStatusItem Preferred Position <autosaveName>`。在创建 item **之前**写入这个值，macOS 27 是否还按它摆放？用户 ⌘ 拖动后这个键怎么变？
2. 退路：清掉自己 item 的已存位置，再按目标顺序从右往左依次创建（利用「后创建的在左边」）。验证它在已有其他 app 的 item 时是否稳定。
3. 两条路都要测：重启 app 后顺序是否保持；与合并模式切换时是否互相干扰。

## 4. 设想的做法（probe 后与用户确认）

- 设置页「菜单栏」顶部加一个可拖拽的列表（`reorderable()`，调研报告 §2.4），列出开着的 widget。打开时按 item 当前在屏幕上的顺序排列；用户在菜单栏上 ⌘ 拖动后，列表跟着变。
- 拖完按 probe 结论应用：写位置键，或清位置后按顺序重建。
- 合并模式下，这个列表就是「合并顺序」，两边合成一份。
- 只排 SysInfo 自己的 item。

## 5. 验收要点

- 本机与 M4 各验一遍：拖拽后菜单栏顺序立刻改变，重启后保持；⌘ 拖动后列表同步；合并 / 拆开往返不乱。
- 开销：设置页不开时没有任何额外开销。

## 6. probe 结果（2026-10-20，M5 Pro 与 M4 Pro，macOS 27.0.1 26A434）

探针：`research/probes/menubar-order/`（`mborder.swift` + `exp.sh`，33 次启动；原始输出按 `.gitignore` 只留在本地）。两台机器**逐步结果一致**。⌘ 拖动用 CGEvent 合成，修饰键成对发送，事后核对无残留。

### 6.1 文档与 SDK 怎么说（先于实验核对）

| 来源 | 内容 |
|---|---|
| `NSStatusItem.h`（27.0 SDK） | `autosaveName` 用于「persisting visibility information」；设为 nil「resets the automatically chosen name and clears saved information」。`isVisible` 按 `autosaveName` 持久化 |
| `NSStatusBar.h` | 只有 `statusItem(withLength:)` / `removeStatusItem(_:)`，没有设置位置或顺序的 API |
| 文档 `removeStatusItem(_:)` | 移除后，左边的 item 右移补位 |
| 文档 `autosaveName` | 「saving and restoring information about a status item」；多 item 的 app 应逐个设名字；没提位置 |
| HIG「Menu bar extras」 | 无法预测 item 的位置；由用户决定放不放 |
| macOS 26 / 27 发布说明 | 没有 status item 位置相关的改动 |

`NSStatusItem Preferred Position <名字>` 这个键在 SDK 与文档里都没有，属于未公开实现细节。27 上系统也不再往 app 的 defaults 域写任何 `NSStatusItem*` 键：位置记忆存在 app 之外（推测在受 TCC 保护的 ControlCenter 组容器里，读不了）。

### 6.2 实测（下面「记忆」指系统按 autosaveName 记住的位置）

| 编号 | 现象 |
|---|---|
| 基线 | 没有记忆时完全按创建顺序摆：**后创建的在左**，整组落在当时所有 status item 的左边。有没有 autosaveName 都一样 |
| 记忆 | 只有用户 ⌘ 拖动过才产生记忆，而且一次拖动会记下本 app **全部** item 的位置；之后重启不论按什么顺序创建，都还原成记住的位置 |
| N（nil） | **失败**。把 autosaveName 设为 nil 再移除重建、或重启，记忆都还在；文档说的「clears saved information」清不掉位置记忆 |
| P（未公开键，对照） | `removeStatusItem` 会删掉这个键；先移除、再写键、再创建则有效，重启后保持，还能把 item 插到其他 app 的 item 之间。但**一旦有记忆，记忆压过键**，加上 nil 也一样 |
| R（换名字） | **可行**。换一组从没被记住过的 autosaveName，按目标顺序从右往左创建，顺序立即生效；之后每次启动按同样顺序、同样名字创建，顺序保持（R3、R4） |
| R · 单个开关 | 只重新打开一个 widget 时，它落到本组最左边，顺序就乱了；整组重建才能恢复（R5） |
| R · 其他 app | 用户把我们的 item 拖到别的 app 的 item 右边后，换名字重建会把整组重新聚在一起，放到最左边（R6）；拖动形成的穿插位置会丢失 |
| 合并往返 | 移除全部 → 建合并 item → 再拆开：有记忆时回到记住的位置，没有记忆时按创建顺序摆（N5、P8） |

### 6.3 由此推出的做法（待用户确认后记为 D92）

- **顺序由 app 保存**：一份 `menuBarOrder`，单 widget 模式和合并模式共用（取代 `menuBarMergedOrder`）。
- **应用顺序 = 换一代名字整组重建**：autosaveName 加代号后缀（如 `<bundle id>.cpu.usage.g3`），代号存进设置；移除全部 item，再按保存的顺序从右往左创建。打开一个 widget、合并或拆开时，也同样整组重建。只用公开 API。用到的行为里，「新名字没有已保存的信息」符合文档语义，「后创建的在左」则只是实测现象，加进运行时自检（创建后核对 `screenOrder()`）。
- **用户 ⌘ 拖动**：系统会给当前这一代名字产生记忆，重启时由系统还原；app 读 `screenOrder()`，把它同步回 `menuBarOrder`，设置页的列表跟着变。
- **第一次上线**：先读一次 `screenOrder()` 作为初始顺序，再换到第一代名字。
- **已知限制**：每次应用顺序时，整组都会移到所有 status item 的最左边，用户拖到其他 app 的 item 之间的穿插位置会丢；系统里会残留旧代名字的记忆（看不到，也清不掉）。
- **不采用**：nil（无效）；未公开的 Preferred Position 键（有记忆时无效，并且依赖未公开行为）。
- **还没测**：整组重建时有没有可见的闪烁；旧代名字的记忆会不会出现在系统设置的菜单栏页面里。实现时用截图自查。
