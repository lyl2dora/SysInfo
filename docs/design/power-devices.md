# 电源设备模块：实现规格

> 日期：2026-10-19。边界与实测见 `docs/design/power-devices-boundary.md`，决策见 D84。
> 本文是实现规格，§11 是偏离记录。

## 1. 范围（D84）

- **UPS**：IOPS 基本项（电量、剩余时间、供电状态、输入电压）+ HID 扩展遥测（负载、电池电压、状态位、阈值、额定值、自检结果、生产日期）。
- **蓝牙配件**：私有 IOPS 里的全部 `Accessory Source`，按 `Group Identifier` 合并成一台设备。
- **内置电池**：只用公开 IOPS 的基础项，`Type = InternalBattery` 才算；标「未在真机验证」。
- 只读；不写 UPS；不链接蓝牙框架；HID 只匹配 usage page 0x84。

## 2. 数据模型（`SysModel/PowerDevices.swift`，发布后不改名）

### 2.1 设备

```swift
public enum PowerDeviceKind: String { case ups, internalBattery, accessory }

/// 设备键：只在内存与设置里用，不含设备唯一标识（D84 PD7）。
/// - UPS：`ups:<vendorID>:<productID>`，同型号多台时追加 `:<序号>`（按 HID location ID 排序，序号只在本次运行有效）；
/// - 内置电池：`battery`；
/// - 配件：`accessory:<Group Identifier 的 SHA-256 前 6 字节>`（同一次运行内稳定；不写历史、不写日志明文）。
public struct PowerDeviceKey: RawRepresentable, Hashable, Codable, Sendable

public struct PowerDevice: Hashable, Sendable {
    var key: PowerDeviceKey
    var kind: PowerDeviceKind
    var name: String                 // IOPS Name；配件为空时按 Group / Part 拼（§4.1）
    var transport: String?           // USB、Bluetooth LE、Internal …
    var parts: [PowerDevicePart]     // UPS / 内置电池只有一项 .main；配件按 Part 拆开
    var powerSourceState: PowerSourceState   // .external / .battery / .unknown
    var timeToEmpty: Double?         // 秒；IOPS「Time to Empty」（分钟）× 60，-1 / 0 / 65535 视为未知
    var timeToFull: Double?          // 秒
    var vendorID: Int?, productID: Int?
}

public struct PowerDevicePart: Hashable, Sendable {
    var role: PowerDevicePartRole    // main, combined, left, right, case, other(String)
    var name: String
    var level: Double?               // 0…1；Current / Max Capacity
    var isCharging: Bool, isCharged: Bool
    var lowWarnLevel: Double?        // 0…1
}

public struct PowerDeviceSnapshot: Hashable, Sendable {
    var time: Date
    var devices: [PowerDevice]       // 排序：UPS → 内置电池 → 配件（按名称）
    var accessoriesAvailable: Bool   // 私有 IOPS 自检通过
    var primaryUPS: PowerDevice?     // devices 里第一台 UPS
}
```

### 2.2 UPS 扩展遥测

```swift
public struct UPSStaticInfo: Hashable, Sendable {        // 设备接入、打开面板时读一次
    var ratedActivePower: Double?          // W，ConfigActivePower
    var ratedInputVoltage: Double?         // V，Input.ConfigVoltage
    var lowTransferVoltage: Double?, highTransferVoltage: Double?   // V
    var batteryNominalVoltage: Double?     // V，Battery.ConfigVoltage
    var manufactureDate: DateComponents?   // HID 日期编码：(年-1980)×512 + 月×32 + 日
    var selfTestResult: UPSSelfTestResult? // 1 通过 2 警告 3 错误 4 中止 5 进行中 6 未做过
    var remainingCapacityLimit: Double?    // 0…1，低电量关机阈值
}

public struct UPSStatusFlags: OptionSet, Hashable, Sendable {
    acPresent, charging, discharging, needReplacement, overload, communicationLost,
    shutdownImminent, belowRemainingCapacityLimit, remainingTimeLimitExpired, voltageNotRegulated
}

public struct UPSTelemetry: Hashable, Sendable {           // 每次采样
    var time: Date
    var load: Double?              // 0…1，PercentLoad
    var loadPower: Double?         // W，load × ratedActivePower（估算，D84 PD4）
    var inputVoltage: Double?      // V
    var batteryVoltage: Double?    // V
    var charge: Double?            // 0…1，RemainingCapacity（自检对照用）
    var runtime: Double?           // 秒，RunTimeToEmpty
    var flags: UPSStatusFlags
}
```

### 2.3 MetricID（只给主 UPS，D84 PD6）

| MetricID | 单位 | 来源 | 质量 |
|---|---|---|---|
| `devices.ups.charge` | ratio | IOPS | measured |
| `devices.ups.runtime` | s | IOPS（Time to Empty） | measured；外接电源时 UPS 自己的估算照样输出 |
| `devices.ups.inputVoltage` | V | HID（偏离记录：IOPS 的 Voltage 由电池供电时是电池电压） | measured |
| `devices.ups.onBattery` | 0 / 1 | IOPS（Power Source State） | measured |
| `devices.ups.load` | ratio | HID | measured |
| `devices.ups.loadPower` | W | HID | **estimated** |
| `devices.ups.batteryVoltage` | V | HID | measured |

没有 UPS 时不输出这些样本（不是不可用：设备不存在）；HID 读不到时 HID 三项为不可用（`readFailed` / `selfTestFailed`）。

## 3. 私有层（`CSysPrivate/ps.c`，`CSP_LAYER_VERSION` 3）

```c
int csp_ps_available(void);                       // IOPSCopyPowerSourcesByType 解析到
CFTypeRef csp_ps_copy_by_type(int type);          // 返回 blob，交给公开 IOPSCopyPowerSourcesList 解析
int csp_ps_acc_notify_available(void);            // IOPSAccNotificationCreateRunLoopSource
CFRunLoopSourceRef csp_ps_acc_notify_create(void (*callback)(void *), void *context);
```

`PrivateLayer.Availability` 加 `accessoryPowerSources`。

## 4. 采集层

### 4.1 `PowerSourceMonitor`（共享，非采集器；`PowerSourceMonitor.shared`）

- 在自己的串行队列上跑一个 run loop 线程，挂公开 `IOPSNotificationCreateRunLoopSource` 与私有配件通知；任一通知后 **1 s 去抖**，重建快照，代数加一，回调订阅方（app、记录器）。外接电源时实测每分钟约 2 次。
- 重建：私有 `IOPSCopyPowerSourcesByType(0)` 可用时以它为准（含 UPS、内置电池、配件），否则用公开 `IOPSCopyPowerSourcesInfo`（只有 UPS 与内置电池）。单次约 18 µs。
- 解析规则：
  - `Type` 为 `UPS` → UPS；`InternalBattery` → 内置电池；`Accessory Source` → 配件；其余类型忽略并记一次日志（不把任何电源都当成电池，调研报告 §2.5）。
  - 配件：`Part Identifier = Combined` 的项展开它的 `Combined Parts`（左右耳），同一 `Group Identifier` 的其余项（Case）并入同一台设备；设备名取 Combined 项的 `Name`，部件名取 `Part Name`，没有时按「设备名 + 左耳 / 右耳 / 充电盒」拼。名字为空的单独部件（`pmset -g accps` 偶见）同样按 Group 归位。
  - `Is Present = false` 的项跳过。
- 不保存 `Accessory Identifier`、`Power Source ID`。
- 自检（由 `devices.sources` 采集器调用）：公开快照可读（必需）；私有按类型可用、能被公开列表解析、每项 `Type` 非空（提示；失败时 `accessoriesAvailable = false`，配件不显示，面板注明）。

### 4.2 `PowerSourceCollector`（`devices.sources`，inline）

- `sample()` 取监视器的最新快照（不额外读 IOPS），输出主 UPS 的 `charge`、`runtime`、`inputVoltage`、`onBattery`。供菜单栏 widget、历史需求使用；快照本身由 app 直接读 `PowerSourceMonitor.shared.latest`。
- 唤醒、系统 build 号变化时引擎会复检；复检时强制重建一次快照。

### 4.3 `UPSTelemetryCollector`（`devices.ups`，blocking）

- HID：公开 IOHIDManager，匹配 `PrimaryUsagePage = 0x84`，只用 `IOHIDDeviceGetReport(kIOHIDReportTypeFeature)`；匹配回调维护设备列表（接入 / 移除时重建元素表、清空静态信息）。只在有需求时打开 manager，180 s 没有采样后关闭（偏离记录）。
- 元素表：遍历 feature 元素，按（父集合 usage、usage）建索引；同一项有多份时按 PowerSummary → Battery → PresentStatus → 其他集合的优先级取一份；记下它的报告 ID 与位偏移（按元素顺序累加 `ReportSize × ReportCount`，报告首字节是报告 ID）。
- 取值：读到的位段按 `logicalMinimum < 0` 决定有无符号（实测 8 位的 230 不能读成 −26）；单位按元素的 `unit` 与 `unitExponent` 换算（电压 0xf0d121 → V，功率 0xd121 → W，时间 0x1001 → s）；单位缺失时按 HID 电源设备规范的默认单位，并在诊断页标注。
- 每次采样读常用报告（含电量与剩余时间、状态位、输入电压、负载、电池电压，M5 上 9 个报告，约 0.22 ms CPU、墙钟约 3 ms）；静态项在设备接入、`refreshStatic()`（面板打开时 app 调用）时读一次。
- 输出主 UPS 的 `load`、`loadPower`、`batteryVoltage`，并把完整的 `UPSTelemetry` 与 `UPSStaticInfo` 放在属性里给 app 读。
- 自检：
  - 能匹配到 0x84 设备（没有 UPS 时为提示级通过：「无设备」不是失败）；
  - 有设备时：HID 电量与 IOPS 电量相差 ≤ 2 个百分点、HID 输入电压与 IOPS 电压相差 ≤ 2 V（必需）；关键元素（PercentLoad、RemainingCapacity、ACPresent）都找得到（提示）。
  - 运行中连续 3 次对照不一致 → 复检；复检不过则 HID 三项不可用，IOPS 基本项照常。

### 4.4 需求

| 消费者 | 采集器 | 间隔 |
|---|---|---|
| 电源设备 widget | `devices.sources` | 模块常驻间隔（跟随全局）。数值来自事件驱动的快照，采样只是取出 |
| 面板「电源设备」tab 可见 | `devices.sources` 1 s、`devices.ups` 2 s（D84 PD3） | — |
| 历史（background） | `devices.sources`、`devices.ups` 60 s（只在有 UPS 时登记 `devices.ups`） | — |
| 诊断页 | 同面板 | — |

ThrottleMonitor 的「UPS / 电池放电」信号（K20）保持原样，不改用本模块的监视器。

## 5. 历史

- `HistoryModule.devices`，开关「记录电源设备历史」（默认开）。没有 UPS 时什么也不写。
- 分钟表：`devices.ups.charge`、`.load`、`.inputVoltage`（instant）。`loadPower` 由 load × 额定功率算出，不入库；`runtime`、`batteryVoltage` 不入库。
- **供电区间**（D84 PD6）：新表 `ups_power_span(id INTEGER PRIMARY KEY, start_s REAL NOT NULL, end_s REAL)`，记 UPS 由电池供电的区间。监视器回调里比对主 UPS 的 `powerSourceState`：转为电池时开一条，转回外接电源时关闭；退出、停止记录时关闭；启动时把上次未关闭的按上次提交时刻关闭（同电源断言）。schema 版本 3 → 4，过期清理沿用分钟表的保留期。
- 导出：`metadata.json` 加 `upsPowerSpans`（起止时刻）。

## 6. App 层

### 6.1 菜单栏

| widget | 小标签 | 数值 | 定宽依据 |
|---|---|---|---|
| `deviceBattery`（出厂关） | 按设备：UPS / BAT / 配件名首字母缩写 | 电池图形 + 「87%」；UPS 由电池供电时数值改为剩余时间「27m」「1h05」 | 「100%」 |

- 绑定（`devices.widget.target`）：`auto`（默认：UPS → 内置电池 → 电量最低的配件）、`ups`、`battery`、`accessoryLowest`。绑定的设备不在时显示「—」，设置保留。
- 电池图形：模板色外框，内部按电量填充；充电时加闪电；UPS 放电时填充改用语义色 `systemOrange`，低于设备自报的低电量阈值时 `systemRed`。
- 点击打开「电源设备」tab。

### 6.2 面板「电源设备」tab（`PanelTab.devices`，切换器标签「电源」）

- 没有任何设备时：切换器里隐藏；从 widget 点进来时显示空状态「没有检测到 UPS、电池或配件」。
- **UPS 卡**：
  1. 标题行：型号名、供电状态胶囊（外接电源 / 电池供电，后者橙色）；
  2. 大号电量 + 剩余时间；
  3. 负载：「23% · 约 138 W」与最近 2 分钟的负载曲线；注释「接在这台 UPS 上的所有设备，按额定 600 W 估算」；
  4. 输入电压「228 V」与切换阈值「176–294 V」，电池电压「27.3 V / 额定 24 V」；
  5. 状态：异常位（需更换电池、过载、通信中断、即将关机、低于剩余容量限）有则红字列出，没有时一行「状态正常」；
  6. 次要信息（折叠，默认收起）：自检结果、生产日期、低电量关机阈值。
  - HID 不可用时第 3–6 项换成一行「扩展信息不可用」和原因，IOPS 部分照常。
- **内置电池卡**：电量、充电状态、剩余时间或充满时间；注释「未在真机验证」。
- **配件卡**（每个 Group 一张，紧凑）：设备名；每个部件一行「左耳 100% · 充电中」。私有接口不可用时整组换成一行说明。
- 刷新：卡片内容由快照变化驱动；UPS 遥测 2 s。

### 6.3 设置页「电源设备」（D41 分节）

- **菜单栏**：`deviceBattery` 的开关、颜色、绑定。
- **历史**：记录开关。
- 不提供间隔设置（D84 PD3 固定）。

### 6.4 诊断页

- 数据路径：IOPS（公开 / 私有）与通知是否挂上、最近一次重建时刻与原因；HID 设备数、元素表（关键项的报告 ID、位偏移、单位、是否按默认单位）、最近一次读取耗时、自检对照值。
- 原样列出每台设备的 IOPS 字段（键名白名单，不含 `Accessory Identifier`、`Power Source ID`、序列号）。

## 7. 命令行

- `devices [--json]`：设备清单（与面板同一套解析）、主 UPS 的 HID 遥测与静态信息。
- `devices --watch 秒`：事件驱动地打印快照变化与通知时刻（用于 PD8 放电实测）。

## 8. 测试

- 单测：IOPS 解析（UPS、内置电池、配件 Combined + Case、名字为空、未知类型、不在位）、设备键、HID 位段解析与有无符号、单位换算、日期解码、主 UPS 选择、widget 绑定解析、供电区间开合、MetricID 与历史目录。
- 硬件测试（`SYSINFO_HW_TESTS=1`）：有 UPS 时 HID 与 IOPS 对照；没有时监视器与采集器正常返回空。

## 9. 开销测量

`make measure` 增加 `devices` 档（面板固定在电源设备 tab）。出厂默认档不变（widget 出厂关）。结果在 `docs/perf/power-devices.md`。

## 10. 跨机验收

- M5：UPS + AirPods 全部功能；放电实测（PD8，用户拔市电 ≤ 60 s）。
- M4：无设备路径（tab 隐藏、widget 显示「—」、CLI 输出空清单、自检为提示级通过）。

## 11. 偏离记录

- 2026-10-19：HID 取值改由内核解析（§4.3 原写按元素顺序自己算位偏移）。每个报告只对其中一个元素用 `IOHIDDeviceGetValueWithOptions(…, withUpdate)` 发一次 GET_REPORT，同一报告的其余元素用 `withoutUpdate` 读内核刚更新的值。不依赖「元素枚举顺序 = 报告里的位序」这个假设，填充位也不用管。M5 实测与 IOPS 对照一致，8 位的输入额定电压读成 230（没有被当成有符号数）。
- 2026-10-19：UPS 名字带固件号（APC：「Back-UPS RS 1000G FW:899.L2 .I USB FW:L2」），面板标题被中间截断。标题只取「 FW:」之前的型号，固件号放进 UPS 卡的「更多」。
- 2026-10-19：配件的部件名改按角色显示（左耳 / 右耳 / 充电盒）。系统给的部件名是「AirPods Pro 🅛」这种，与设备名重复。
- 2026-10-19：面板切换器多了「电源」后共 8 项，360 pt 宽里两字标签被折成两行。超过 7 项时把每项左右留白从 8 pt 收到 3 pt，并限制为单行（自查截图发现）。
- 2026-10-19：菜单栏电池图形不画充电闪电（§6.1）。图形只有 7 pt 高，闪电画不清；充电状态在面板里看。
- 2026-10-19：HID manager 的空闲关闭由 60 s 改为 180 s（§4.3）。60 s 与历史的采样间隔相同，后台每次采样都赶上刚关闭，每分钟要重开一次；开着闲置时实测不占 CPU。
- 2026-10-19（PD8 放电实测）：IOPS 的 `Voltage` 不总是输入电压：由电池供电时报电池电压（约 24 V），恢复市电后 15 s 以上仍停在 26 V。`devices.ups.inputVoltage` 改由 HID 输出（断电时 0 V，面板显示「无市电」）；IOPS 的电压只在外接电源且 ≥ 80 V 时才当作输入电压；HID 与 IOPS 的电压对照只在外接电源时做。放电时两边的电量估算一秒一跳，同一时刻差到 6 个百分点，电量对照的容差由 2 个百分点放宽到 10 个（对照只为抓解码错误这类大偏差）。
- 2026-10-19：`sysinfo-cli devices --watch` 的输出改为按行刷新（放电实测时重定向到文件，中途查看不丢记录）。
- 2026-10-19：诊断页打开时也登记电源设备的需求（IOPS 2 s，有 UPS 时 HID 2 s），与其他模块的诊断读数一致。
