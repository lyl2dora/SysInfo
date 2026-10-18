# SysInfo

macOS 菜单栏系统监控，面向 Apple 芯片 Mac。

- **模块**：CPU、功耗与散热、内存、存储、网络、GPU 与加速器（含 ANE 估算）、应用活动。
- **菜单栏**：每个 widget 显示一项指标，可以合并为单个项目；点开是统一面板，拖动即成浮窗。
- **历史**：分钟级历史保存在本机，可导出为 CSV 或 JSON Lines。
- **开销**：出厂配置常驻约 0.2% 单核，只在有人看时采样。

## 系统要求

macOS 27.0 或更新，Apple 芯片。

## 下载

在 [Releases](https://github.com/lyl2dora/SysInfo/releases) 下载，已签名并经 Apple 公证。app 内可以检查更新。

## 隐私

- 默认唯一的网络连接是每周一次检查更新（只访问本仓库的 GitHub Releases），可在设置里关闭。
- 网络延迟检测、公网 IP 查询默认关闭，开启后才连接。
- 不申请定位、蓝牙、辅助功能等授权；采集的数据只保存在本机，导出不含设备唯一标识。

## 说明

读取传感器、功耗等数据用到了 SMC、IOReport 等系统私有接口。系统更新后，个别数据源若未通过自检，会显示为「不可用」，而不是错误的数值。

## 构建

需要 Xcode 27。`make help` 列出全部目标，常用的有 `make build`、`make test`。

## 许可证

[MIT](LICENSE)。第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
