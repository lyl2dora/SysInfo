# 存储模块：能力边界与实现规格

> 日期：2026-10-16。决策见 `docs/decisions.md` D53–D55（顺序、边界由用户改定，SMART 频率按实测定）。
> 本文 §1–§2 是边界（实测与结论），§3 起是实现规格，§11 是偏离记录。
> 证据：`research/probes/storage-module/`（2026-10-16，M5 Pro 与 M4 Pro 只读比对）、`research/probes/disk/`、`research/probes/disk-review/`（2026-09-28，只在 M5 上测过）。

## 1. 两台机器的能力矩阵

| 项 | M5 Pro（Mac17,16） | M4 Pro（Mac16,11） | 结论 |
|---|---|---|---|
| 物理盘 | 内置 APPLE SSD AP1024Z（Apple Fabric）+ 5 块外置 INTEL SSDPF2NV153TZ（PCI-Express，雷电） | 内置 APPLE SSD AP1024Z | 按 `IOBlockStorageDevice` 的 Protocol Characteristics 判定物理盘 |
| 非物理盘 | 磁盘映像 ×3（Virtual Interface / File）、模拟器 cryptex、RAID 虚拟盘 disk11 | 磁盘映像 ×3 | Virtual Interface、位置为 File 的一律排除；RAID 虚拟盘不在 `IOBlockStorageDevice` 下，天然排除 |
| AppleRAID | 「Media」Stripe（RAID 0），5 成员，76.8 TB，Online | 无 | IORegistry `AppleRAIDMember` / `AppleRAIDStripeSet` 的 `AppleRAID-SetStatus`、`AppleRAID-MemberStatus`、`AppleRAID-LevelName` 可读，不用 `diskutil` |
| NVMe SMART（公开 `NVMeSMARTLibExternal.h`） | 6 块全部可读 | 可读 | 主路径 |
| SMART 温度传感器 1–8 | 全为 0（不支持） | 同 | 只有综合温度；传感器字段存在才显示 |
| WCTEMP / CCTEMP（Identify） | Intel 70 / 80 °C；Apple 为 0 | Apple 为 0 | 有值才显示「警告 / 严重温度阈值」 |
| 通电时间 | Apple 32 h（明显偏低，机器用了数月）；Intel 约 1.9 万 h | Apple 1727 h | Apple 控制器（VID 0x106B）照常显示，标「控制器低报，不可信」（D54） |
| 可用备用块阈值 | Apple 99%，Intel 10% | Apple 99% | 判定「低于阈值」按各盘自报的阈值，不写死 |
| 控制器忙碌时间 | Apple 恒为 0；Intel 有值 | Apple 0 | Apple 上标「不支持」：值为 0 且 VID 为 Apple 时显示「—」 |
| Identify 版本号 | Apple 0x0；Intel 1.4 | Apple 0x0 | 只进详情页 |
| `IOBlockStorageDriver` Statistics | 每块物理盘都有（含 RAID 成员） | 有 | 吞吐、IOPS、平均延迟、错误与重试计数 |
| NVMe 电源状态（IOReport「NVMe Power States」） | 6 个控制器 60 s 内 100% ACTIVE，无论是否每秒读 SMART | 100% ACTIVE | 外置 Intel 盘 APSTA=0（不支持自主电源切换），内置 ANS 只有 OFF/ACTIVE。**轮询 SMART 不会改变盘的电源状态** |

### 1.1 SMART 开销（线程 CPU，探针实测）

| 方式 | M5 内置 | M5 外置（每块） | M4 内置 |
|---|---|---|---|
| 每次重建 plugin + 读 | 0.78 ms（墙钟 2.0 ms） | 0.70–0.78 ms（墙钟约 1 ms） | 0.98 ms（墙钟 1.7 ms） |
| 常驻 plugin，只读 | 0.13 ms（墙钟 1.3 ms） | 0.16–0.18 ms（墙钟 0.34 ms） | 0.17 ms（墙钟 1.0 ms） |
| 首次建 plugin | 2.9 ms | 0.1 ms | 4.6 ms |

所以 plugin 常驻（盘消失时释放）；6 块盘全读一次约 1 ms CPU。出厂默认档已有 0.41%（M5），盘温 widget 出厂打开后不能每秒读全部盘：只每次读 widget 绑定的盘，其余盘按面板与历史的需要读（§4.2「焦点盘」）。

## 2. 边界（D54）

- **纳入**：
  - 物理盘清单（内置 / 外置、接口、型号、固件、容量、RAID 成员关系），热插拔时更新；
  - 每盘吞吐、IOPS、平均延迟、累计错误与重试；
  - 每盘 SMART 全字段；
  - 容量：按「容量组」显示（内置盘上的 APFS 容器、RAID 组、外置盘上的卷），含卷构成；
  - AppleRAID 阵列状态与成员状态；
  - 按磁盘 IO 的 Top N（coalition 6/7 号槽）；
  - 历史。
- **菜单栏**：盘温（出厂开）、读写速率（上下两行，出厂关）、可用空间（出厂关）。
- **只进诊断页**：数据路径、每盘的 SMART 连接状态与耗时、NVMe 节流计数（IOReport `BW Limits`，展开时才订阅，标「未验证」）。
- **划出**：每应用磁盘 IO 历史 → 应用活动。
- **不做**：弹出 / 卸载；ATA SMART；自检命令；`system_profiler`、`diskutil`、`iostat` 常驻调用（CLI 的 `verify storage` 手动运行一次 `iostat`、`df` 作对照）。

## 3. 数据模型（`SysModel/StorageMetrics.swift`，发布后不改名）

### 3.1 盘的标识

- `DiskKey`：12 位十六进制，= SHA-256(本地盐 ‖ 序列号 ‖ 型号) 的前 6 字节。盐是首次使用时随机生成的 16 字节，存在本进程的 defaults（`storage.identitySalt`），所以 app、Debug 版、CLI 各自的键不同。序列号本身不出进程、不进日志、不进历史库（CLAUDE.md）。
- 没有序列号的盘（部分 USB 桥）退回 IORegistry 路径（换口后变成另一块盘）。
- RAID 组的键 = SHA-256(盐 ‖ "raid" ‖ 阵列 UUID) 的前 6 字节。
- 导出时盘的键换成「型号 + 位置」（如「INTEL SSDPF2NV153TZ · RAID 成员 3」），映射存在历史库的 meta 表（`storage.labels`）。

### 3.2 结构信息（不随 tick 变化，采集器以属性提供，app 直接读，同功耗模块的 PMGR 批次）

- `PhysicalDisk`：键、型号、固件、厂商 ID、位置（internal / external）、接口名、BSD 名、容量、块大小、介质（SSD / HDD / 未知）、是否支持 NVMe SMART、RAID 成员关系（组键、成员序号、成员状态）。
- `RAIDSet`：键、名称（卷名，用户数据，可以显示）、级别、状态、容量、成员键（按成员序号）、BSD 名。
- `CapacityGroup`：归属（某块盘或某个 RAID 组）、名称、总量、可用、已用、卷列表（名称、角色、挂载点、已用）、可清除空间（只给启动卷所在组，60 s 缓存）。
- `SMARTRecord`：NVMe 健康日志的全部字段 + Identify 里的阈值与版本 + 读取时刻 + 标注（`powerOnHoursUnreliable`、`busyTimeUnsupported`）。

### 3.3 MetricID（`<k>` 为盘或组的键）

| MetricID | 单位 | 说明 |
|---|---|---|
| `storage.disk.<k>.read` / `.write` | B/s | 驱动 Statistics 差分（interval） |
| `storage.disk.<k>.readOps` / `.writeOps` | 1/s | 同上 |
| `storage.disk.<k>.readLatency` / `.writeLatency` | s | Δ总时间 ÷ Δ次数；区间内没有 IO 时不可用（`noIO`） |
| `storage.disk.<k>.temp` | °C | SMART 综合温度 |
| `storage.disk.<k>.life` | ratio | 已用寿命（Percentage Used，可超过 100%） |
| `storage.disk.<k>.spare` | ratio | 可用备用块 |
| `storage.disk.<k>.mediaErrors` | count | 介质与数据完整性错误 |
| `storage.disk.<k>.warning` | 位 | critical warning 字节 |
| `storage.disk.<k>.dataRead` / `.dataWritten` | B | 累计读写（SMART 数据单元 × 512 000） |
| `storage.group.<k>.total` / `.available` / `.used` | B | 容量组 |

不另设「%busy」：Total Time 在并发 IO 下重叠计数，算不出忙碌率（调研报告 §1.4）。

## 4. 采集层

### 4.1 `DiskInventory`（共享，非采集器）

- 遍历 `IOBlockStorageDevice`：Protocol Characteristics 的接口为 `Virtual Interface`、位置为 `File` 或缺失的跳过；其余为物理盘。整盘 `IOMedia`（Whole = Yes）给出 BSD 名与容量；递归找 `AppleRAIDMember` / `AppleRAID*Set` 节点得到 RAID 关系；找 `AppleAPFSContainer` / 叶子 `IOMedia` 得到容量组与卷。
- IOKit 匹配通知（`IOBlockStorageDevice` 发布 / 终止）在私有队列上把代数加一；采集器下一次采样时重新枚举（防抖 1 s）。RAID 与卷状态随容量采集器每次刷新。
- 自检：至少找到一块物理盘（必需）；每块盘都有整盘 `IOMedia`（提示）。

### 4.2 `StorageIOCollector`（`storage.io`，inline）

- 每次读全部物理盘驱动的 Statistics（IORegistry 一次取一个字典）。计数回退或盘重新出现 → 该盘这一段不可用（`counterReset`），不钳为 0。
- 自检：至少一块盘有 Statistics（必需）。

### 4.3 `SMARTCollector`（`storage.smart`，blocking）

- plugin 常驻，盘消失或自检时释放；读失败一次就重建一次 plugin，再失败该盘不可用。
- **焦点盘**：app 设置 `focus`。nil = 每次读全部盘（面板存储 tab 可见、诊断页、CLI）；一个集合 = 每次只读这些盘（菜单栏 widget 绑定的盘），其余盘最多每 60 s 读一次（给历史）。
- 非 NVMe 盘：温度等指标不可用（`notSupported`）。
- 自检：每块 SMART 盘读一次，综合温度在 −20–120 °C、已用寿命 ≤ 255、备用块 ≤ 100（提示项，逐盘）；一块都读不到时不可用。

### 4.4 `StorageCapacityCollector`（`storage.capacity`，blocking）

- 刷新 RAID 与卷状态；容量组：APFS 容器的总量取容器 `IOMedia` 大小，可用取容器内任一已挂载卷的 `statfs`（同容器共享），已用 = 总量 − 可用；卷的已用取 `getattrlist(ATTR_VOL_SPACEUSED)`；非 APFS 卷直接用 `statfs`。
- 可清除空间：启动卷的 `volumeAvailableCapacityForImportantUsage` − `statfs` 可用，最多 60 s 一次（15–60 ms）。
- 只读本地挂载点，不碰网络卷。

### 4.5 Top N（`AppSampler` + `TopNBuilder.buildDisk`）

- `CoalitionUsage` 加 6/7 号槽（累计读 / 写字节），`CoalitionDelta` 加差分；按读 + 写降序。
- 同 uid 成员用 `ri_diskio_bytesread/written` 差分（`TopNModel` 保留上一次的成员计数）；外部成员合计 = coalition 差分 − 同 uid 之和，钳到 ≥0。
- 回退（coalition 不可用）：只列同 uid 进程。

### 4.6 需求

| 消费者 | 采集器 | 间隔 |
|---|---|---|
| 盘温 widget | `storage.smart`（焦点 = 绑定的盘，「最高温」时为全部） | 存储模块常驻间隔（跟随全局，默认 1 s） |
| 读写 widget | `storage.io` | 同上 |
| 可用空间 widget | `storage.capacity` | 60 s |
| 面板存储 tab | `storage.io` 1 s、`storage.smart` 按设置（默认 2 s，焦点 = 全部）、`storage.capacity` 10 s、Top N 按设置（默认 2 s） | — |
| 历史（background） | `storage.io` 60 s、`storage.smart` 60 s、`storage.capacity` 60 s | — |
| 诊断页 | 同面板，另加节流计数（展开时） | — |

## 5. 历史（schema 不变）

- `HistoryModule.storage`，由「记录存储历史」开关控制（默认开）。
- 入库：每盘读写（interval，B/s）、温度（instant）、已用寿命、备用块、介质错误、累计读写（instant）；每组已用与可用（instant）。6 块盘约每分钟 50 行，小时级永久保留，长期磨损与写入趋势从小时表看（D54 的「每天一份快照」由小时表覆盖，不另建表）。
- 不入库：IOPS、延迟、critical warning（变化时写日志）。
- 盘的标签（型号 + 位置）在提交时写进 meta 表，导出时替换键。

## 6. App 层

### 6.1 菜单栏

| widget | 小标签 | 数值 | 定宽依据 |
|---|---|---|---|
| `diskTemperature` | SSD | 「45°」 | 「125°」 |
| `diskThroughput` | （R / W 两行） | 「R 1.2M」「W 340K」 | 「R 999M」 |
| `diskFree` | FREE | 「812G」「1.2T」 | 「99.9T」 |

- 速率按 1000 换算（与访达、活动监视器一致），< 10 保留一位小数。
- 读写 widget 固定画成上下两行（同 Stats 的 twoRows），R / W 两个字母代替小标签；关闭小标签时只画数值。
- 绑定：盘温可选「内置盘 / 任意一块盘 / 所有盘最高温」，读写可选「内置盘 / 任意一块盘」，可用空间可选容量组。默认都是内置盘。绑定的盘不在了（外置盘拔掉）时显示「—」，设置保留。

### 6.2 面板「存储」tab

- **概览页**：
  1. 分组「内置」「RAID ‹名称›」（每个阵列一组）「外置」，没有的组不出现；RAID 组可以折叠，默认展开，状态存设置。
  2. 组标题：名称、状态（RAID）、容量条与「已用 / 总量」。
  3. 每块盘两行：第一行名称（内置盘为型号，RAID 成员为「成员 n · 型号」）与「温度 · 寿命 x%」；有异常时右侧换成异常项（critical warning、备用块低于阈值、介质错误 > 0、RAID 成员不在线）。第二行读写速率与最近 60 s 的读写小曲线。
  4. 盘多于 7 块时，盘列表放进限高滚动区。
  5. Top N（按磁盘 IO）。
- **单盘详情页**（点击某块盘进入，左上角返回）：读写历史图（R 主线、W 叠加线，纵轴 B/s）、IO 统计（IOPS、平均延迟、累计错误与重试）、SMART 分组（健康、温度、累计、其他）、身份（型号、固件、接口、容量、块大小）。内置盘与非 RAID 外置盘另列卷构成。
- 切换方式同 D47：原地换内容，面板按新内容改高。

### 6.3 设置页「存储」（D41 分节）

- **菜单栏**：三个 widget；展开后选择绑定的盘或组。
- **采集**：常驻间隔覆盖、面板 SMART 间隔、Top N 间隔（标注开销）。
- **面板**：Top N 行数与分组、图表跨度。
- **历史**：记录开关。

### 6.4 诊断页

- 存储数据源：每块盘的 BSD 名、接口、SMART 连接与最近一次耗时、IO 错误与重试；容量组；RAID。
- NVMe 节流：折叠，展开时订阅 IOReport「NVMe」组的 `BW Limits` 与 `Time weighted throttle statistics`，原样列出，注明含义未经验证（外置 Intel 盘的 Throttle Time 等于总时长，疑似单位或语义不同）。

## 7. 命令行

- `storage [--interval 1] [--count 3] [--json]`：盘清单、吞吐、SMART 摘要、容量组。
- `smart [--json]`：每盘 SMART 全字段。
- `disktop [--rows 10] [--count 1] [--json]`：按磁盘 IO 的 Top N。
- `verify storage`：与 `iostat -d`（同一时间窗）、`df -k`（容量）对照。

## 8. 测试

- 单测：标识哈希、物理盘判定、SMART 结构解析（金样本字节）、IO 差分与复位、延迟、Top N 磁盘组装、历史入库规则、格式化。
- 硬件测试：至少一块物理盘、内置盘 SMART 可读、温度在范围内、容量组之和不超过物理容量。

## 9. 开销测量

`make measure` 的出厂默认档改为四个 item（加盘温）；新增 `storage` 档（面板固定在存储 tab）。结果在 `docs/perf/storage.md`。

## 10. 跨机验收

M4 只有内置盘：外置盘、RAID、雷电 SMART 只在 M5 上验收（D54）。

## 11. 偏离记录
