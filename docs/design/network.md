# 网络模块：能力边界（讨论稿）

> 日期：2026-10-17。§3 的 N1–N9 已由用户全部按推荐确认，见 `docs/decisions.md` D60–D62。
> 证据：`research/probes/network-module/`（2026-10-17，M5 Pro 与 M4 Pro 同步实测，macOS 27.0.1 26A434）；早期只在 M5 上测过的 `research/probes/network/`（2026-09-28）。
> 「M5」「M4」分别指开发机 Mac17,16 与对照机 Mac16,11。

## 0. 测了什么

- **结构比对**（`net_struct.c`）：两台机器逐接口列出 IFMIB 类型与标志、IOKit 背后的控制器、内置标志、链路速率与状态、SIOCGIFMEDIA、SCNetworkInterface 类型、有无 IPv4 / 全局 IPv6 地址，以及 SCDynamicStore 的主接口。
- **计数器对账**（`net_watch.c`）：从 M4 经 ssh 向 M5 传 1.30 GB 零字节（约 20 s），两边每秒读 IFMIB，与载荷字节比对。
- **真实节奏开销**（`costbench_net.c`、`wifi_cost.swift`）：每秒醒来一次，每次只读一项，取中位数。
- **K47 本地网络授权**（`icmp_app.c`）：做一个 Developer ID 签名、用 `open` 启动的独立 .app（自己就是 responsible process），依次发 ICMP、UDP、TCP，用截图和返回值判断会不会弹授权框、会不会被拦。

## 1. 实测结果

### 1.1 接口：两台机器的同与不同

| 项 | M5 | M4 | 结论 |
|---|---|---|---|
| 接口总数 | 40 | 27 | M5 多出的是 5 台虚拟机的 vmenet / bridge 和几个 utun。数量不能写死 |
| 主接口 | en0，10GBASE-T | en0，10GBASE-T | 两台都是有线为主，Wi-Fi 同时连着（en1 有地址） |
| en0 驱动 | `AppleSkywalkAVBLegacyEthernet` | `AppleEthernetAquantiaAqtion113` | 同样是内置 10 GbE，控制器类不同。不能按类名识别以太网 |
| 以太网链路速率 | IOKit `IOLinkSpeed` = 10000 Mbps | 相同 | 1.9 ms/次，只在链路变化或面板打开时读，缓存 |
| Wi-Fi 链路速率 | IOKit `IOLinkSpeed` = **0** | **0** | Wi-Fi 速率只能用 CoreWLAN `transmitRate` |
| Wi-Fi | Wi-Fi 7（PHY 11be），5 GHz ch149 / 80 MHz | Wi-Fi 6（11ax），5 GHz ch36 / 160 MHz | CoreWLAN 无授权字段两台都可读 |
| CoreWLAN `transmitPower` | 17 mW | **1496 mW**（不可信） | 不显示 |
| 雷电 IP 端口 en2/3/4 | 内置，`IOLinkSpeed` 80 Gbps，链路 inactive | 相同 | 它们是 Thunderbolt Bridge（bridge0）的成员，不单独显示 |
| `anpi*`、`en4–6`（M5）/ `en5–7`（M4） | `AppleUSBDeviceNCM`，SC 类型也是 Ethernet，常年 inactive | 相同 | Mac 作 USB 设备时用的接口。按控制器排除，或者只因为 inactive 不显示 |
| 虚拟接口 | utun×11、vmenet×5、bridge100–104、awdl0、llw0 | utun×6、vmenet×1、bridge100、awdl0、llw0 | 都没有 IOKit 背后的物理控制器（vmenet 是 `IOUserEthernetController`） |
| vmenet `iqdrops` | 1.4×10¹³ 等垃圾值 | 1.0×10¹⁶ | 两台都有，`IOUserEthernet` 接口的丢包数不可信 |
| 全局 IPv6 | utun8/9/10 也有 | 没有 | 不能靠「有可路由地址的 utun」判断 VPN（M5 上代理软件未开时也有） |

### 1.2 计数器准确性（M4 → M5，1 298 874 368 字节载荷，约 70 MB/s）

| 计数 | 字节 | 相对载荷 | 解释 |
|---|---|---|---|
| M4 en0 发送 | 1 308.73 MB | +0.76% | 发送端开了 TSO，按大段计数，一个 64 KB 段只算一次头 |
| M5 en0 接收 | 1 366.66 MB | +5.2% | 接收端按线上的每个包计数，包含以太网头 + IP/TCP 头（约 66 B / 1368 B 载荷，估算 +4.8%） |
| M5「全部非回环接口合计」 | 1 366.81 MB | — | 这次虚拟机空闲，合计与 en0 相同。虚拟机或 VPN 有流量时，同一份数据会在 vmenet、bridge、utun、en0 上重复计数 |

- 每秒差分平稳（69.3–69.7 MB/s），没有回绕、量化或负差值。64 位计数没有问题。
- 两台的差异是协议头的计数口径，不是误差。界面显示的是**接口字节**（含协议头），不是应用载荷。
- 没测到 10 GbE 线速：两台机器不在同一网段，中间链路只有约 560 Mbps。

### 1.3 VPN：代理软件的增强模式（TUN）开启后（M5，2026-10-17 用户开启）

- 路由与配置：默认路由、SCDynamicStore 的 `PrimaryInterface` 都变成 **utun9**（`PrimaryService` 是代理软件的 VPN 服务，`Router` 198.18.0.1）；DNS 变成 198.18.0.2（假 IP，域名都解析到 198.18.x）；系统 HTTP / HTTPS / SOCKS 代理同时指向 127.0.0.1。私有网段走 `ExcludedRoutes` 直连 en0（发往 M4 的路由仍是 en0）。
- 计数对账（从国内镜像下载 2 306 457 582 字节，15 s，约 154 MB/s ≈ 1.2 Gbps）：

| 计数 | 入向字节 | 相对载荷 |
|---|---|---|
| utun9 | 2 344.28 MB | +1.6%（隧道内只有 IP 头） |
| en0 | 2 420.28 MB | +4.9%（线上实际流量，同 §1.2） |
| 全部非回环接口合计 | 4 764.70 MB | **约 2 倍**（同一份数据在 utun9 和 en0 上各计一次） |

- 结论：
  - 开了 TUN 型 VPN 后，**en0 才是真实的线上流量**；utun 只是隧道内层，而且走系统代理（127.0.0.1 → 代理软件 → en0）的流量根本不经过 utun，utun 会低估。所以「主接口」应当是隧道下面的物理接口，不是 `PrimaryInterface`。
  - 找下层物理接口：`Setup:/Network/Global/IPv4` 的 `ServiceOrder` 里第一个有 `State:/Network/Service/<id>/IPv4`、且 `InterfaceName` 不是隧道的服务（实测为 en0 的以太网服务）。全部是公开的 SCDynamicStore 键，随变更通知更新。
  - 判定「VPN 中」：`PrimaryService` 有 `State:/Network/Service/<id>/VPN` 子键，或者 `PrimaryInterface` 是 utun / ipsec / ppp。不能靠「有带地址的 utun」（§1.1：代理软件未开时 utun8/9/10 也有全局 IPv6）。
  - 顺带验证了 1.2 Gbps 下 64 位计数正常。

### 1.4 读取开销（线程 CPU，中位数；M5 / M4）

| 项 | M5 | M4 | 用在哪 |
|---|---|---|---|
| IFMIB 读一个接口（含 `if_nametoindex`） | 0.27 ms | 0.30 ms | 缓存 index 后约 0.09 ms（减去下一行的枚举开销） |
| IFMIB 读全部接口（枚举 + 逐个 sysctl） | 0.29 ms | 0.29 ms | 面板、历史 |
| 只枚举接口（`if_nameindex`） | 0.18 ms | 0.20 ms | 不需要定时做，接口变化有通知 |
| `getifaddrs` | 0.18 ms | 0.20 ms | 只取地址，变化时读 |
| SCDynamicStore 读两个 Global 键 | 0.16 ms | 0.37 ms | 收到变更通知时读 |
| IOKit 链路速率 | 1.94 ms | 1.87 ms | 链路变化或面板打开时读，缓存 |
| SIOCGIFMEDIA | 0.08 ms | 0.16 ms | 链路状态 |
| CoreWLAN 读 7 个字段 | 0.91 ms | 1.45 ms | 只在面板里（D10）；首次创建客户端 2.3 / 4.1 ms |
| `nettop -P -L 1` 一次 | **67 ms** CPU，墙钟 5 s | **44 ms** CPU，墙钟 30 s | 远高于调研报告的「约 20 ms」，单次调用不可用（见 N6） |

按 1 s 读一个缓存 index 的接口估算：网速 widget 常驻约 **0.01% 单核**；面板打开、每秒读全部接口约 0.03%。

### 1.5 K47：ICMP 与本地网络授权

| 发往 | 结果 |
|---|---|
| 默认网关（ICMP、UDP） | 放行，不弹窗；授权框挂起期间也照常放行 |
| 其他网段的私有地址（经路由） | 放行 |
| 同网段另一台设备（TCP，阳性对照） | `EHOSTUNREACH`，**弹出授权框**（证明这个 app 受本地网络隐私约束） |
| 同网段另一台设备（ICMP） | `EHOSTUNREACH`，被拦（终端里 ping 同一台设备是通的） |
| 公网 | 放行 |

- 结论：**ICMP 受本地网络隐私约束**，但发往默认网关不受限。所以测网关延迟不需要授权；测局域网内其他设备需要授权，违反 D22「默认不弹授权」，只能做成用户主动开启。
- 另一个发现：两台机器所在的网络里，`1.1.1.1` 和 `8.8.8.8` 都是 0.5–0.9 ms、TTL 62，被本地设备（软路由或代理）代答，测不到真实外网延迟。`223.5.5.5` 是真实的（20 / 26 ms，TTL 52）。

## 2. 跨机型差异与未验证项

- 只有两台台式机，都是有线 10 GbE 为主、Wi-Fi 同时在线。没测笔记本（只有 Wi-Fi，`IOBuiltin` 和主接口切换会更频繁）、USB / 雷电以太网转接器、启用中的 Thunderbolt Bridge（D20）。
- VPN 只测了代理软件的增强模式（§1.3）。只开系统代理、不开 TUN 时，主接口不变，无需特殊处理；IKEv2 / WireGuard 等系统 VPN 没测，按同一规则（`PrimaryService` 带 VPN 子键）处理。M4 没装代理软件。
- 计数器验证到约 1.2 Gbps（§1.3）；10 GbE 线速没实测。
- CoreWLAN 事件（`CWEventDelegate`）能注册，事件是否投递仍未测。
- 本模块用到的都是公开接口（IFMIB sysctl、IOKit 网络属性、SystemConfiguration、CoreWLAN、ICMP DGRAM socket），**不需要私有层**。`SIOCGIFLINKPARAMS` 不在公开头文件里，不用；链路速率用 IOKit。

## 3. 需要拍板的事项

### N1 显示哪些接口，「主接口」是谁
- **A（推荐）**：
  - 主接口 = 默认路由所在的接口（SCDynamicStore `State:/Network/Global/IPv4` 的 `PrimaryInterface`，IPv4 没有时看 IPv6），收到变更通知时更新，不轮询。默认路由是隧道（utun / ipsec / ppp）时，主接口改为隧道下面的物理接口（`ServiceOrder` 中第一个有 IPv4 状态的非隧道服务，§1.3），并在面板标「VPN」；隧道本身作为一行显示在接口列表里，注明「隧道内层，经系统代理的流量不计在这里」。
  - 面板列出**活跃的物理接口**：有 IOKit 背后的控制器、不是 `IOUserEthernet` / `AppleUSBDeviceNCM`、且链路 active 或有地址。Thunderbolt Bridge 以 bridge0 一行出现，成员端口不单列。
  - 虚拟接口（utun、vmenet、虚拟机 bridge、awdl、llw）默认折叠成「虚拟接口」一组，可以展开。
  - 任何地方都**不把所有接口加起来**（虚拟机和 VPN 流量会重复计数）。「物理接口合计」只加物理接口，彼此不重复。
- **B**：列出全部接口，不分类。40 个接口里有 30 多个无用，且合计会失真。

### N2 菜单栏 widget
- **A（推荐）**：
  - 「网速」：一个 widget 上下两行显示 ↑ / ↓，同存储读写速率，算 D38「一个 widget 一项」的例外。绑定「主接口（自动跟随）」，也可选某个接口或「物理接口合计」。
  - 单位默认字节 / 秒（同活动监视器，K24），可改成比特 / 秒。
  - 「延迟」：只在 N3 开启延迟后可选。
  - 出厂：**网速打开**（常驻约 0.01% 单核），延迟关。这是对 D51「以后模块的 widget 默认关」的例外，同存储盘温（D54）。
- **B**：同 A，但网速出厂也关（严格按 D51）。

### N3 延迟（K47）
- **A（推荐）**：默认关（D22：默认没有出站连接）。在设置里开启时让你选目标：
  - 「默认网关」：实测不需要授权，但只反映局域网（0.5–0.7 ms）；
  - 「自定义公网地址」：默认填 `223.5.5.5`，旁边说明 `1.1.1.1` / `8.8.8.8` 在你的网络里被代答；
  - 两个可以同时开。同网段其他设备不在选项里（需要本地网络授权）。
  - 只在网络面板可见或延迟 widget 打开时发包，间隔不少于 2 s（默认 5 s）。显示 RTT 与丢包率，IPv6 回包按 type 和 id 过滤。设置的「隐私」页列出这个出站目标。
- **B**：只做网关延迟，不做公网。
- **C**：v1 不做延迟。

### N4 公网 IP（K48）
- **A（推荐）**：面板里放「查询公网 IP」按钮，点一次发一次 HTTPS 请求，结果只显示不存历史；服务地址是设置项（默认留空，第一次点击时让你填或选一个）；不做归属地。设置的「隐私」页列出它。
- **B**：不显示公网 IP。
- **C**：网络变化时自动查询（与 D22 冲突，不推荐）。

### N5 Wi-Fi 卡片的读取节奏（D10 的落实）
- **A（推荐）**：只在面板里 Wi-Fi 卡片可见时读（Wi-Fi 是活跃接口才有这张卡），每 5 s 一次（0.9–1.5 ms/次，约 0.03% 单核），面板关闭立即停。显示 RSSI、噪声、SNR、发送速率、信道 / 频段 / 带宽、PHY；不显示发送功率（M4 读出 1496 mW）。D10 的「不轮询」理解为后台不读。
- **B**：面板打开时只读一次。RSSI 不会随走动或干扰更新。

### N6 每应用流量 Top N（D09 原定 P1）
- **A（推荐）**：维持 P1，网络面板这次不放 Top N。实测 `nettop` 单次调用要 44–67 ms CPU、墙钟 5–30 s，单次调用的路线不可用；P1 开工时改测常驻流式模式（`nettop -L 0 -s N`，面板可见时才启动），一并定 K49。
- **B**：这次就做，用流式 nettop，只在网络面板可见时运行。开销还没测，可能吃掉面板 2% 预算的一大块。

### N7 历史与流量统计
- **A（推荐）**：每个活跃物理接口和主接口按分钟记入 / 出字节（差分，负值按复位丢弃，睡眠留空），按现有规则汇总成小时。面板显示「今日 / 本月」流量（按主接口，可切换接口）。开启延迟时，RTT 和丢包也按分钟记。面板关闭时 background 层每 60 s 读一次全部接口（0.29 ms）就够，计数是累计值，不丢流量。
- **B**：只记主接口，不做今日 / 本月统计。

### N8 面板内容（无须逐条拍板，列出供确认）
- 概览：主接口（类型、名称、链路速率、VPN 标记）、实时 ↑↓ 曲线、今日 / 本月流量。
- 接口列表：活跃物理接口各一行（速率 + 短曲线），虚拟接口一组折叠。
- 连接信息：本机 IPv4 / IPv6、网关、DNS（取 Global 键，反映 VPN 解析器）、代理是否开启；地址点一下可复制。都是变更通知驱动。
- Wi-Fi 卡片（N5）、延迟卡片（N3）、公网 IP 按钮（N4）。

### N9 只放诊断页（无须拍板，列出供确认）
全部接口的原始 IFMIB（包数、错误、丢包、组播、冲突；`IOUserEthernet` 的丢包标「不可靠」），接口分类依据（控制器类、SC 类型、内置标志），链路速率来源，SCDynamicStore 原始键，NWPath 的 `linkQuality` / expensive / constrained，CoreWLAN 原值。

### 不做
SSID / BSSID、定位权限、Wi-Fi 扫描（D10、D22）；局域网设备发现与 Bonjour（需要本地网络授权）；测速（speedtest）；逐连接列表；任何改变网络设置的操作。

## 附：复现

```bash
cd research/probes/network-module
xcrun clang -O2 -o net_struct net_struct.c -framework IOKit -framework CoreFoundation -framework SystemConfiguration && ./net_struct
xcrun clang -O2 -o costbench_net costbench_net.c -framework IOKit -framework CoreFoundation -framework SystemConfiguration && ./costbench_net 30 en0
xcrun swiftc -O -o wifi_cost wifi_cost.swift -framework CoreWLAN && ./wifi_cost
./build_icmp_app.sh && open -n build/ICMPProbe.app --args icmp <网关>
```
