# CPU 模块自身开销测量

> 由 `make measure` / `make remote-measure`（`scripts/measure-overhead.sh`）追加，口径见 M0 设计 §9、CPU 模块设计 §10、K26：
> - 「app」是 SysInfo 进程的 CPU 占用，按单核的比例（100% = 占满一个核），由 `ps -o time=` 的差值算出；
> - MenuBarAgent、WindowServer 是同一时段的 CPU 增量，是软指标：它们也在为其他 app 工作，要和「基线」（不运行 SysInfo）对照看；
> - 构建为 Release 配置，Bundle ID 改为 `.dev` 并带 `--factory-defaults` 启动，不碰日用版的偏好（D16、D18）；对照机用 ad-hoc 签名、经 `open` 启动（D39）；
> - 目标（D19 出厂默认配置）：默认 < 0.5%，面板打开 < 2%。

## 2026-10-15 14:38 · 6578606（build 60）

- 机器：Mac16,11，Apple M4 Pro，14 个逻辑核，macOS 27.0.1 (26A434)
- 预热 30 s，每档测量 120 s

| 档位 | app CPU（单核 %） | MenuBarAgent（%） | WindowServer（%） | app footprint | 备注 |
|---|---|---|---|---|---|
| 基线（不运行 SysInfo） | — | 0.042 | 1.549 | — |  |
| 出厂默认（1 个 CPU 占用 item，面板关闭，历史开启） | 0.516 | 0.000 | 1.824 | 19 MB |  |
| 面板打开（CPU tab，Top N 5 行） | 5.089 | 0.000 | 7.970 | 180 MB |  |
| 面板打开 + 详情与中断来源展开 | 5.514 | 0.000 | 8.704 | 182 MB |  |

## 2026-10-15 14:46 · 3ef73f7（build 61）

- 机器：Mac17,16，Apple M5 Pro，18 个逻辑核，macOS 27.0.1 (26A434)
- 预热 30 s，每档测量 120 s

| 档位 | app CPU（单核 %） | MenuBarAgent（%） | WindowServer（%） | app footprint | 备注 |
|---|---|---|---|---|---|
| 基线（不运行 SysInfo） | — | 0.008 | 12.838 | — |  |
| 出厂默认（1 个 CPU 占用 item，面板关闭，历史开启） | 0.367 | 0.050 | 16.618 | 12 MB |  |
| 面板打开（CPU tab，Top N 5 行） | 3.157 | 0.000 | 33.547 | 122 MB |  |
| 面板打开 + 详情与中断来源展开 | 3.407 | 0.025 | 34.962 | 124 MB |  |
