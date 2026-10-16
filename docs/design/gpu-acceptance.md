# GPU 与加速器模块验收报告

> 日期：2026-10-16。范围：D57–D59（分支 `module/gpu`）。边界实测、规格与偏离记录见 `docs/design/gpu.md`。

## 结论

- D57 列的内容全部完成：
  - 数据：GPU 活跃（GPUPH）与平均频率、GPU 温度（档案代表键）、ANE 开 / 关与估算功率（D58）、媒体引擎活动、GPU 内存；
  - 界面：按 GPU 时间的 Top N，三个菜单栏 widget（GPU 功率从功耗模块移来，偏好键不变），面板 tab，设置页，诊断页（含折叠的「GPU 细节」）；
  - 历史与 CLI（`gpu`、`gputop`）。
- 精度：两台的 AGX 功率、各应用 GPU 能耗合计、ANE 估算都已与 PMGR 30 分钟批次对账；GPU 活跃与负载程序自报的忙碌时间对照过（§1）。
- 出厂默认与 GPU 面板的开销都在 D19 预算内（§2）。
- 实现中有 5 处偏离规格，都记在 `gpu.md` §9。其中两处请你验收时确认：
  - 图表从「叠加功率」改成「活跃 / 功率」二选一；
  - 媒体引擎底数改成「本次运行最小值 + 10 个样本学习期」。

## 1. 逐项结果

| # | 项目 | M5 Pro | M4 Pro |
|---|---|---|---|
| 1 | 结构比对（`gpu_struct`）：GPUPH、DVFS 表、ANE 节点、媒体中断、PMP、Tg / Ta、coalition 槽位 | GPUPH 16 态；表 `voltage-states9` 13 档 338–1620 MHz；ANE 在 Exclave 后面 | GPUPH 16 态；表 15 档 338–1578 MHz（中间不单调）；ANE 中断可读 |
| 2 | AGX `GPU Energy` 积分 ÷ PMGR GPU 批次（完整 30 分钟窗口） | 1.002 | 0.991 |
| 3 | coalition 槽位 41 合计 ÷ PMGR GPU 批次 | 1.002（与 AGX 逐焦耳相等） | 0.991 |
| 4 | ANE 估算（槽位 39 合计）÷ PMGR ANE 批次 | 0.919 | 0.931 |
| 5 | GPU 活跃 vs 负载程序自报忙碌（满载 / 50% / 25% 占空） | 100% / 57% / 40% vs 100% / 44% / 22%（M5 关断滞后，偏高已在设置与面板注明） | 100% / 50% / 26% vs 100% / 46% / 24% |
| 6 | `Device Utilization %` 失真确认（不采用） | 25% 占空读 62 | CPU + GPU 满载读 8，满载读 0 |
| 7 | 温度代表键（5 个）最大值 vs 全部有效 Tg 最大值，逐秒之差 | p95 0，最大 0.2 °C | p95 0，最大 0.16 °C；GPU 关断时显示「—」 |
| 8 | 媒体引擎中断 vs 帧率（HEVC / H.264 编码、HEVC 解码、ProRes） | 2× / 2× / 3.4× / 1× 帧率；avd 空闲底数 ~90/s 被学习扣除 | 2× / 2× / 3.3× / 1× 帧率；底数 0 |
| 9 | ANE 上电 / 关断滞后 | 0.5–0.6 s / 5.5–6.2 s | 0.6–0.8 s / 5.3–5.6 s |
| 10 | `sysinfo-cli gpu --diag` | 自检全过；档位表来自档案；ANE 中断「缺失」（Exclave） | 自检全过；GPU 关断时频率 `deviceIdle`、温度 `sensorPowerGated` |
| 11 | 单测（`make test`） | 213 个全部通过 | — |
| 12 | 硬件测试（`make test-hw`、`make remote-test`） | 213 个中 212 个通过；未通过的是 `app.coalition.slots` 提示项（能耗槽逐位相等 51/60 < 90%）。`main` 上同样 51/60（已在临时 worktree 核对），与本模块无关。另有一次 `StorageHardwareTests.internalSMARTIsPlausible` 偶发失败（并行测试争用独占的 SMART 连接，D56），重跑通过 | 213 个全部通过；第一次跑时 `StorageHardwareTests.focusLimitsReadsToFocusedDisks` 偶发失败（同样是 SMART 独占争用），重跑通过 |

## 2. 开销（`docs/perf/gpu.md`，D40 口径）

| 档位 | M5 | M4 |
|---|---|---|
| 出厂默认（四个 widget，面板关闭，历史与能耗开启；新增 GPU 历史每 10 s） | 0.31% | 0.30%* |
| 面板打开（GPU tab，温度 / ANE / 媒体 2 s，coalition 2 s，Top N 5 行） | 1.55% | 0.83% |

- 预算：出厂默认 < 0.5%，面板打开 < 2%。两台都在预算内。
- 带 * 的是 M4 上最快档时间太少，按周期数估算的值。
- 真实节奏单项（`costbench_gpu`）：GPUPH 与 GPU Energy 合并订阅 1.30 / 1.60 ms（与只读功率相同）；5 个温度键约 0.5 ms；ANE 状态 + GPU 内存 0.25 / 0.42 ms；媒体中断 0.39 / 0.52 ms。

## 3. 截图与 computer use 自查（按 D18 不代替你的验收）

| # | 项目 | 结果 | 自查中发现并已修正的问题 |
|---|---|---|---|
| 1 | GPU 面板（M5，空闲与 25 s 混合负载：GPU 50% 占空 + ANE 2 线程 + HEVC 编码） | 负载下：活跃 100%、1.62 GHz、17.5 W、65 °C；ANE「工作中」3.59 W；视频编码「工作中」；Top N 首行 ANE 3.59 W | 灰色说明文字在玻璃背景上几乎看不见（改用 secondary 色）；脚注过长被截断（拆成两行） |
| 2 | GPU 面板（M4，`remote-app-shot`） | 活跃 2%、338 MHz、43 °C；媒体三行「空闲」；Top N 为 WindowServer | — |
| 3 | 设置页：打开三个 widget | 菜单栏依次出现 GPU 温度、功率、活跃（51° / 0.5W / 53%），开关后预览就地展开 | — |
| 4 | 点击 GPU 活跃 widget | 面板显示 GPU 模块，锚在 widget 下方 | — |
| 5 | 再点 GPU 功率 widget | 面板原地移到它下方，仍是 GPU 模块（D47） | — |
| 6 | 展开 Top N 一行 | 列出同 uid 成员与结束按钮，「另有 12 个你的进程」 | — |
| 7 | 诊断页 GPU 部分 + 展开「GPU 细节」 | 档位表、各档驻留、温度键、ANE 节点、媒体底数、ANE 对账「等待批次」；展开后有 PWRCTRL、节流驻留、AF BW、ANE 中断「读不到」 | — |

## 4. 需要你亲手验收的部分

1. 菜单栏里打开 GPU 活跃 / 功率 / 温度，看数值、宽度、颜色设置；点击各 widget 开合面板，与其他模块的 widget 来回切换。
2. 已经打开过 GPU 功率 widget 的日用版：升级后它应该仍然开着、位置不变（偏好键沿用 `menubar.power.gpuPower.*`，autosaveName 沿用 `.power.gpuPower`）。
3. 功耗与散热设置页：菜单栏节里不再有 GPU 功率，改为一行链接到「GPU 与加速器」页。
4. 跑一段 GPU / ANE / 视频编码负载，看面板与 Top N 的表现；放一段视频解码，看「视频解码」是否从空闲变成工作中。
5. 30 分钟后看诊断页「ANE 估算 ÷ PMGR ANE」是否给出比值（需要窗口内有 ANE 负载，均值 ≥ 0.05 W 才下结论）。
6. 偏离记录 §9 的两处确认：图表二选一、媒体底数的学习方式。

## 5. 过程中的一次失误（已处理）

实现期间一条命令里误带了 `scp -r . user@remote-host:/tmp/sysinfo-remote/dummy`，把本地 `Packages/SysKit`（含 `.build`，约 931 MB）复制到了对照机。当即中止并删除了该目录。只写到 D18 允许的 `/tmp/sysinfo-remote`，没有其他影响。
