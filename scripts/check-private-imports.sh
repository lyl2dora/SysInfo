#!/bin/bash
# 私有 C 层隔离检查（D05、D23）：给定目录下的源码不得引用 CSysPrivate。
#
# 为什么需要它：Xcode 和 SwiftPM 会把依赖闭包里所有 C target 的 module map 传给下游编译
# （-fmodule-map-file=…/CSysPrivate.modulemap），所以「CSysPrivate 不做成 product」并不能让 app
# 在编译期 import 不到它（见 docs/design/m0-skeleton.md 偏离记录）。这里在构建时检查源码，发现就让构建失败。
# 这是隔离的唯一防线，所以宁可误报：
# - 先去掉注释（Swift 的块注释可以嵌套）；Swift 源码另外去掉字符串字面量；
# - 剩下的代码里只要出现标识符 `CSysPrivate` 就算违规，不管它在不在行首、前面有没有别的语句
#   （`import Foundation; import CSysPrivate`、`/* x */ import CSysPrivate`、`@preconcurrency import …`、
#   `import struct CSysPrivate.foo`、`#include "CSysPrivate.h"`、`@import CSysPrivate;` 都会命中）。
# 回归样例见 scripts/test-check-private-imports.sh（make test 会先跑它）。
#
# 用法：scripts/check-private-imports.sh <目录>...
# 由 app target 的 Run Script 阶段（检查 App/）和 make test / test-hw / cli / remote-cli（检查 App/ 与 sysinfo-cli）调用。
# 任何读取失败都按失败处理（fail closed），不会静默放行。
set -uo pipefail

if [ "$#" -eq 0 ]; then
    echo "用法：$0 <目录>..." >&2
    exit 64
fi

# 对每个文件逐行扫描，输出「文件:行」。状态（块注释深度、多行字符串）按文件重置。
# shellcheck disable=SC2016
awk_program='
FNR == 1 { depth = 0; inml = 0; swift = (FILENAME ~ /\.swift$/) }
{
    line = $0; code = ""; i = 1; n = length(line)
    while (i <= n) {
        c = substr(line, i, 1); c2 = substr(line, i, 2); c3 = substr(line, i, 3)
        if (inml) {                                   # Swift 多行字符串 """ … """
            if (c3 == "\"\"\"") { inml = 0; i += 3 } else { i++ }
            continue
        }
        if (depth > 0) {                              # 块注释（Swift 可以嵌套）
            if (swift && c2 == "/*") { depth++; i += 2 }
            else if (c2 == "*/") { depth--; i += 2; if (depth == 0) code = code " " }
            else { i++ }
            continue
        }
        if (c2 == "//") break                         # 行注释
        if (c2 == "/*") { depth = 1; i += 2; continue }
        if (swift && c3 == "\"\"\"") { inml = 1; i += 3; code = code " "; continue }
        if (c == "\"") {
            # Swift：去掉字符串内容；C/ObjC：原样保留（#include "CSysPrivate.h" 的路径在引号里），
            # 只是不把引号里的 // 或 /* 当成注释。
            j = i + 1
            while (j <= n) {
                d = substr(line, j, 1)
                if (d == "\\") { j += 2; continue }
                if (d == "\"") { j++; break }
                j++
            }
            code = code (swift ? " " : substr(line, i, j - i))
            i = j
            continue
        }
        code = code c; i++
    }
    if (code ~ /(^|[^A-Za-z0-9_])CSysPrivate([^A-Za-z0-9_]|$)/) print FILENAME ":" FNR
}
'

status=0
for dir in "$@"; do
    if [ ! -d "$dir" ]; then
        echo "error: 私有层隔离检查：目录不存在：$dir" >&2
        exit 2
    fi

    hits="$(find "$dir" -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' -o -name '*.mm' -o -name '*.pch' \) \
        -exec awk "$awk_program" {} +)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "error: 私有层隔离检查：读取 $dir 失败（find/awk 退出码 ${rc}）" >&2
        exit 2
    fi

    if [ -n "$hits" ]; then
        # 按 Xcode 能识别的「文件:行: error: 说明」格式输出，IDE 里可直接跳转。
        while IFS= read -r hit; do
            echo "$hit: error: 禁止在这里引用 CSysPrivate：私有 API 只能经 SysCollectors 封装使用（D05、D23）"
        done <<<"$hits"
        status=1
    fi
done
exit "$status"
