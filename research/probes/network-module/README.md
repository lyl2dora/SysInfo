# 网络模块探针（2026-10-17，M5 Pro 与 M4 Pro 同步实测，macOS 27.0.1 26A434）

| 文件 | 内容 |
|---|---|
| `net_struct.c` | 逐接口结构比对：IFMIB 类型 / 标志、IOKit 控制器与内置标志、链路速率、SIOCGIFMEDIA、SC 类型、有无地址（不输出地址与 MAC） |
| `costbench_net.c` | 每秒醒来一次的读取开销（线程 CPU，30 轮中位数）；nettop 单次（子进程 CPU） |
| `net_watch.c` | 每秒 IFMIB 差分，用于两机对账（`out/watch_*.tsv`，载荷字节见 `out/watch_payload.txt`） |
| `wifi_cost.swift` | CoreWLAN 无授权字段的读取开销 |
| `icmp_app.c`、`build_icmp_app.sh` | K47：Developer ID 签名的独立 .app 发 ICMP / UDP / TCP，看本地网络授权（结果整理在 `out/icmp_k47.txt`） |

远端只写 `/tmp/sysinfo-remote/netprobe`。
