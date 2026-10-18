# 1.0.0 发布前实测（D74、D76、D78）

2026-10-18 至 19 日。对象是 CI 手动试跑（workflow_dispatch）产出的 `SysInfo-1.0.0.zip`（build 195，c7f1c81，已签名、公证、staple）；它与发布 tag 的代码只差 D83 的设置页头小修，构建、签名、公证流程相同。正式包由推 `v1.0.0` tag 后的 CI 重新构建。

## 1. Gatekeeper（M4 Pro 对照机）

zip 与 `.sha256` 一致。给 zip 加上浏览器下载同样的 quarantine 属性，`ditto` 解开后 app 也带 quarantine：

| 检查 | 结果 |
|---|---|
| `spctl --assess --type execute` | accepted，source = Notarized Developer ID，Team ID D8MFB2YNN3 |
| `stapler validate` | 通过（票据已 staple，离线可验） |
| `syspolicy_check distribution` | App passed all pre-distribution checks |

首次打开时系统的「从互联网下载」确认框要真实点击，ssh 下做不了，留给正式发布后在 M4 上用浏览器下载时确认（§4）。

## 2. 自动更新端到端（M4 Pro）

做法：本机构建一个测试版（Release 配置、Developer ID 签名、`MARKETING_VERSION = 0.9.9`、带 `UPDATE_TEST_FEED` 编译条件），装进 M4 的 `/Applications`；在 `/tmp/sysinfo-remote/update/` 放上 CI 产物和一个 GitHub Release 格式的 `feed.json`（`file://` 地址），用 `update.testFeedURL` 指过去，打开「自动安装」、删掉 `update.lastCheck`，然后启动。安装前的四项校验（SHA-256、签名与 Team ID / Bundle ID、Gatekeeper、版本号）不因测试地址放松。

| 用例 | 结果 |
|---|---|
| 正向：feed 指向 CI 1.0.0 | 启动约 60 s 后自动检查、下载、校验、原子替换并重新打开；`/Applications` 里变为 1.0.0（195），CDHash 与 CI 产物一致，Gatekeeper 评估通过。做了两次，结果相同 |
| 反向：`.sha256` 改成错误值 | 检查照常完成（`update.lastCheck` 更新），没有安装，仍是 0.9.9 |

- 测试后 M4 上是 CI 的 1.0.0 并在运行；`update.testFeedURL`、`update.autoInstall` 已删除，偏好里只剩原有的键与新的 `update.lastCheck`。
- 观察：校验失败后，下载的 zip 留在 `~/Library/Caches/zone.lyl.sysinfo/Update`（约 5 MB），下次安装前才清空。按设计如此，不改。
- 原先在 M4 上运行的 1.0.0 实例（10-18 17:04 启动）经用户同意后结束。

## 3. Debug 版长时间运行（本机 M5 Pro，p0-acceptance §9 第 3 项）

23:30 用 `make run ARGS="--open-panel --pin-panel --panel-tab=gpu"` 启动，连续运行约 82 分钟，面板一直打开（GPU tab，00:08 起切到功耗 tab），00:53 结束。00:21 跑了 45 s ANE 负载（`aneload2 45 2`，事先告知用户），让 00:19–00:49 这一批里有 ANE 能耗。

| 检查 | 结果 |
|---|---|
| 「最近 30 分钟」卡片 | 00:08 时仍是旧库里的批次，标题为「最近一批（30 分钟）· 10 月 18 日 13:49–14:19 · 9 小时前更新」（e590e21 所说启动后第一批最长要等 1 小时）；00:20 换成「最近 30 分钟 · 23:49–0:19 · 1 分钟前更新」，00:52 换成「0:19–0:49 · 2 分钟前更新」，神经网络引擎 0.10 W |
| 诊断页「ANE 估算 ÷ PMGR ANE」 | **0.927 ✓**（范围 0.80–1.05），与 GPU 模块验收时 M5 的 0.919 一致 |
| 诊断页「PZD1 ÷ PMGR DRAM」 | 1.018 ✓（0.95–1.05） |
| 诊断页「AGX ÷ PMGR GPU」 | 「覆盖不足，这次不下结论」：这一批 PMGR GPU 209.7 J ÷ 1800 s ≈ 0.12 W，低于核对门槛 0.3 W（空闲时比值会飘），按设计不下结论 |
| 遥测对账（最近 60 段） | 漏记 0 段，其余偏差中位数 −0.0% |

切 tab、打开设置与诊断页用的是 CGEvent 合成点击与滚动（不带修饰键，结束后 `flagsState` 无残留）。

## 4. 正式发布后（用户在 M4 上手点）

`v1.0.0` 由 CI 发布（build 203）；下载回的包 SHA-256 一致，Gatekeeper 评估为 Notarized Developer ID，staple 有效。2026-10-19 用户在 M4 上确认以下两项通过：

- 用浏览器下载 `v1.0.0` 的 zip，首次打开时确认系统提示框，app 正常启动。
- 设置「通用」页的登录项开关：打开后系统设置「登录项」里出现 SysInfo，关掉后消失。
