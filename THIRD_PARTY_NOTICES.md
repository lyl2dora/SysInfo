# 第三方声明

app 本体不包含第三方代码。下列调研 probe 为对照测量，逐字复刻了 [Stats](https://github.com/exelban/stats) 的少量读取逻辑，适用 Stats 的 MIT 许可：

- `research/probes/memory/stats_usage_replica.swift`（Stats `Modules/RAM/readers.swift`）
- `research/probes/network/localip.swift` 中标为 (a) 的部分（Stats `Modules/Net/readers.swift`）

另有 `research/probes/network-review/linkparams.c` 按 xnu `bsd/net/if.h` 抄录了结构体布局，用于互操作。

## Stats 的许可

MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
