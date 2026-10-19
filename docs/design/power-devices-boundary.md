# 电源设备模块能力边界（讨论稿）

> 日期：2026-10-19 · 状态：**待拍板** · 分支：`p1/power-devices`
> 只想拍板的话，直接看 §5 的问题（PD1–PD8）。定下来之后，结论追加为新的 D 条目，再另写本模块的实现规格。

## 1. 目的与口径

P1 第一个模块（2026-10-19 用户决定先做电源设备，每应用网络流量往后放）。D13 给它的范围是「UPS / 配件电量」；相关的既有约束：

- D22：配件电量只用私有 IOPS 配件接口；UPS 与电池用公开 IOPS、HID 与 `AppleSmartBattery`；HID 匹配限定 usage page 0x84（读元素时 0x84/0x85），不链接蓝牙框架，不调用 `system_profiler`。
- D24 / K20：UPS 放电已经是降频信号（`ThrottleMonitor`，去抖 5 s），本模块不改它，只复用同一数据源。
- 已知陷阱：不把所有 IOPS 电源都当成电池（调研报告 §2.5）。
- 2026-10-19 用户决定：**内置电池的健康度、循环次数等详情，等有带电池的设备再做**。

依据是 2026-10-19 在两台目标机上的实测（探针在 `research/probes/power-devices/`）：

- 本机 Mac mini M5 Pro，macOS 27.0.1：接 APC Back-UPS RS 1000G（USB），连着 AirPods Pro；没有内置电池（`BatteryInstalled = No`）。
- 对照机 Mac mini M4 Pro，macOS 27.0.1：没有 UPS、配件和电池。用来验证「无设备」路径。

## 2. 两台机器的能力矩阵

### 2.1 IOPS（公开 `IOPSCopyPowerSourcesInfo` 与私有 `IOPSCopyPowerSourcesByType`）

| 项 | M5 Pro | M4 Pro |
|---|---|---|
| 公开列表 | 1 个：UPS（Type = UPS，USB） | 0 个 |
| 私有按类型（0 = 全部） | 3 个：UPS、AirPods 充电盒、AirPods（Part = Combined，内含左右耳两个 Combined Parts） | 0 个 |
| UPS 字段 | 电量 %、`Time to Empty`（分钟）、`Power Source State`、`Is Charging`、输入电压 `Voltage`（mV）、额定电压、名称、Vendor/Product ID | — |
| 配件字段 | 电量、充电中、已充满、低电量阈值、`Accessory Category`（Headset、Audio Battery Case）、`Group Identifier`、`Part Identifier`（Case / Left / Right / Combined）、`Part Name`、传输方式（Bluetooth LE） | — |
| 单次读取开销（快照 + 列表 + 逐个描述） | 线程 CPU 中位数 18 µs | 8 µs |
| 公开变化通知（60 s，外接电源） | 2 次（UPS 的剩余时间在 27/28 分钟之间跳） | 0 次 |
| 配件变化通知 | 60 s 内 0 次 | 0 次 |

说明：

- 调研报告说「有 UPS 时每 1–10 s 通知一次」，这次外接电源时只有每分钟约 2 次。放电时的频率还没测（PD8）。
- UPS 的 `Power Source ID` 在重新插线后变了（9-28 是 21954560，今天是 −2132148224）。**不能拿它做设备键**。
- `Accessory Identifier` 是序列号或 UUID 一类的设备唯一标识，不进库、不进历史，日志里用 `.private`。
- 上午有一次 `pmset -g accps` 里充电盒的名字是空的，探针读 IOPS 时有名字（「AirPods Pro充电盒」）。名字为空时按 Group / Part 拼（系统 BatteryCenter 也是这样做的，见 §3）。

### 2.2 UPS 扩展遥测（HID，usage page 0x84/0x85，只读 GET_REPORT）

| 项 | M5 Pro |
|---|---|
| 匹配 | 按 `PrimaryUsagePage = 0x84` 匹配到 1 台（primary usage 0x84:0x04 UPS）。M4 上匹配为空，3 s 超时后正常结束 |
| feature 元素 | 67 个，分布在 44 个报告 ID 里；同一项会在多个集合里重复（如 PresentStatus 在报告 22 和 122 各一份；电量与剩余时间在 PowerSummary 和 Battery 各一份） |
| 本机读数 | 电量 100%、剩余 1680 s、负载 22–23%、额定有功功率 600 W、输入电压 228 V（额定 230 V，切换阈值 176 / 294 V）、电池电压 27.28 V（额定 24 V）、自检结果 6（按 HID 规范是「未做过自检」）、生产日期编码 21811（解码为 2022-09-19）、状态位（AC、充电、放电、需更换电池、过载、通信中断、即将关机等）全部正常 |
| 读取开销：IOHIDDevice（C） | 常用 9 个报告：CPU 中位数 **0.22 ms**；全部 44 个报告：1.4 ms，墙钟约 11 ms |
| 读取开销：CoreHID（Swift） | 常用 9 个报告：CPU 中位数 0.88 ms；全部 67 个元素：2.9–3.5 ms，墙钟约 13 ms |

CoreHID 实测的三个问题：

1. **每读一次往 stderr 打约 86 行** `CFDictionarySetValue(): attempt to use this function to set a key which is not copyable…`。这是框架内部的问题，在 app 里会进统一日志，按 2 s 节奏读就是每分钟两千多行。
2. **`unit` / `unitExponent` 读出来是空的**（IOHIDManager 同一元素给出 0xf0d121、指数 5），单位只能按 HID 电源设备规范写死。
3. `integerValue` 按位宽做有符号扩展：8 位的「输入额定电压」230 读成 −26。要按 `logicalMinimum ≥ 0` 当无符号读。

IOHIDDevice 没有这三个问题，而且便宜约 4 倍。它是公开的 IOKit 接口，不属于 D05 的私有层。

### 2.3 UPS 负载与 Mac 自身功耗不是一回事

负载 22% × 600 W ≈ 132 W，同一时刻本机整机直流功率（PDTR）只有 9–18 W。UPS 的负载覆盖接在它上面的所有设备（显示器、路由器等），是 UPS 输出侧的有功功率估算。所以：

- UPS 负载功率标「估算」，说明「接在这台 UPS 上的所有设备」；
- 不和 PDTR 相减求「其他设备」：一个是交流输出、一个是直流，口径不同，差值没有意义。

### 2.4 系统「电池」小组件的数据来源（2026-10-19 用户问）

- 小组件是 `Batteries.app` 的 `BatteriesAvocadoWidgetExtension`，数据来自私有 `BatteryCenter.framework`。
- `BatteryCenter` 只链接 IOKit；核心类 `_BCPowerSourceController` 的方法都是对 IOPS 电源列表的解析（`_orderedDevicesFromPowerSourcesBlob:powerSourcesList:`、`_partFromPowerSourcePartIdentifier:`、`_nameForVendor:accessoryCategory:name:partName:isInternal:` 等）。
- 其他设备的电量是系统守护进程替它们发布进 IOPS 的（蓝牙配件由 bluetoothd）。Mac 上能看到的设备范围，就是 Mac 自己 IOPS 里有的设备，与我们走私有 `IOPSCopyPowerSourcesByType` 拿到的一致。
- Apple Watch 配对的是 iPhone，不在 Mac 的 IOPS 里。iPhone / iPad 的电量在 Mac 上只出现在「个人热点」菜单，走 Continuity 的蓝牙广播，需要蓝牙或带 entitlement 的私有服务，与 D13、D22 冲突。

### 2.5 开销估算（D80 口径前的粗算，实现后再按 `make measure` 实测）

| 档位 | 内容 | 估算 |
|---|---|---|
| 常驻 | IOPS 事件驱动（每分钟约 2 次 × 18 µs）+ 若记录历史，HID 常用 9 个报告每 60 s 一次（0.22 ms） | 约 0.004 ms/s，可以忽略 |
| 面板可见 | HID 常用项每 2 s 一次 | 约 0.11 ms/s（约 0.01% 单核） |

## 3. 与调研报告、决策档不同的发现

- 公开 CoreHID 能用，但有日志刷屏、单位缺失、符号扩展三个问题（§2.2）。调研报告 §1.7 把 CoreHID 列为 UPS 扩展遥测的首选，建议改用 IOHIDDevice。
- 外接电源时 IOPS 通知只有每分钟约 2 次，不是 1–10 s 一次。去抖仍然保留。
- `Power Source ID` 重插后会变（§2.1）。

## 4. 建议的模块边界

### 4.1 纳入本模块

- **UPS**（一等支持）：IOPS 的基本项 + HID 扩展遥测（负载 % 与估算瓦数、输入电压与切换阈值、电池电压、自检结果、需更换电池 / 过载 / 通信中断等状态位、生产日期）。
- **蓝牙配件**：私有 IOPS 里有的全部配件（AirPods 左右耳、充电盒等），按 Group 合并成一台设备、按 Part 分行显示。
- **内置电池（基础项）**：只用公开 IOPS（电量、充电状态、剩余时间、电源适配器），`BatteryInstalled` 为真时才显示。两台目标机都没有电池，标注「未在真机验证」。

### 4.2 不做（这次）

- 内置电池的健康度、循环次数、温度、设计容量等 `AppleSmartBattery` 详情（2026-10-19 用户决定：有设备再做）。
- 妙控键盘、鼠标、触控板的电量：如果它们出现在 IOPS 里，按配件自然显示；不另读它们的 HID 属性（D22 的 0x84 限定）。
- iPhone、iPad、Apple Watch 的电量（§2.4）。
- 给 UPS 写任何东西（自检、蜂鸣器、关机延时）：只读。
- 切到电池供电时发通知：属于 P2「提醒」。

## 5. 需要你拍板的问题

### PD1 范围 · 待定
- **A（推荐）**：按 §4.1 与 §4.2。
- B：只做 UPS，配件和内置电池以后再说。

### PD2 读 UPS 扩展遥测的接口 · 待定
- **A（推荐）**：公开 IOHIDManager / IOHIDDevice（C），放在非私有的 C 封装里；元素按「集合 + usage」取，同一项有多份时按 PowerSummary → Battery → 其他的优先级选一份；单位与指数从元素读。
- B：公开 CoreHID（Swift）。代价是日志刷屏、单位要写死、读取贵约 4 倍。

### PD3 HID 读取节奏 · 待定
- **A（推荐）**：面板里「电源设备」tab 可见时每 2 s 读常用 9 个报告；历史记录开着时常驻每 60 s 读一次（与分钟聚合对齐）；其余时间只靠 IOPS 事件。全部 44 个报告（阈值、生产日期等不变的项）只在设备接入和打开面板时读一次。
- B：只在面板可见时读，不进历史。

### PD4 UPS 负载的瓦数 · 待定
- **A（推荐）**：负载 % × 额定有功功率（`ConfigActivePower`），标「估算」，注明覆盖接在 UPS 上的所有设备；不与整机功率相减（§2.3）。额定功率读不到时只显示百分比。
- B：只显示负载百分比。

### PD5 界面 · 待定
- **A（推荐）**：
  - 面板新增「电源设备」tab，没有任何电源设备时隐藏；
  - 每台设备一张卡片：UPS 卡（大号电量与供电状态、剩余时间、负载 % 与瓦数、输入电压与切换阈值、电池电压、状态位、生产日期），配件卡（按 Group 合并，左右耳与充电盒各一行），内置电池卡（基础项）；
  - 菜单栏新增一个可选 widget，出厂不上：显示所选设备（默认 UPS）的电量，UPS 放电时改为显示剩余时间；固定宽度、等宽数字、battery 样式。
- B：不加 tab，在「功耗与散热」tab 里加一张 UPS 卡，配件放进设置的「关于」或不显示。

### PD6 历史 · 待定
- **A（推荐）**：UPS 的电量、负载 %、输入电压按分钟聚合写入历史；供电切换（外接 ⇄ 电池）记成事件区间，沿用应用活动里电源断言区间的写法。配件和内置电池不记。
- B：不记历史。

### PD7 设备标识 · 待定
- **A（推荐）**：UPS 用「Vendor ID : Product ID」做键（同一时刻多台同型号 UPS 时再加 HID 的 location ID，只在内存里用）；配件用 `Group Identifier`，只在内存里用，不写历史和日志明文。都不使用 `Power Source ID`。
- B：用 `Accessory Identifier`（序列号）做键。不推荐：它是设备唯一标识。

### PD8 放电实测 · 待定
外接电源下的表现已经测过，放电时的表现（IOPS 通知频率、剩余时间与负载的变化、状态位、K20 降频的去抖）只有真的断市电才能看到。
- **A（推荐）**：实现完成后验收时，由你拔掉 UPS 的市电插头不超过 60 s 再插回，事先告知。电脑由 UPS 供电，不会断电。
- B：不做放电实测，只靠代码路径的单元测试。

## 6. 自检（D05、D20）

- 私有 `IOPSCopyPowerSourcesByType`：符号存在、返回值能被公开 `IOPSCopyPowerSourcesList` 解析、`Type` 在已知集合内。失败时回退到公开列表（UPS 与内置电池照常，配件显示「不可用」）。
- UPS HID：HID 的电量、剩余时间、输入电压与 IOPS 的同项对照（IOPS 的电量与电压就是系统从同一台 UPS 读的）。连续不一致时 HID 扩展项显示「不可用」，IOPS 基本项照常。
- 复检时机按 D05：启动、唤醒、系统 build 号变化、连续越界，另加设备接入。
