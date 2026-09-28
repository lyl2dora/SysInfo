#!/bin/bash
# 私有 C 层隔离检查（D05、D23）：给定目录下的源码不得 import / include CSysPrivate。
#
# 为什么需要它：Xcode 和 SwiftPM 会把依赖闭包里所有 C target 的 module map 传给下游编译
# （-fmodule-map-file=…/CSysPrivate.modulemap），所以「CSysPrivate 不做成 product」并不能让 app
# 在编译期 import 不到它。这里在构建时检查源码，发现就让构建失败。
#
# 用法：scripts/check-private-imports.sh <目录>...
# 由 app target 的 Run Script 阶段（检查 App/）和 make test（检查 sysinfo-cli）调用。
# 任何读取失败都按失败处理（fail closed），不会静默放行。
set -uo pipefail

if [ "$#" -eq 0 ]; then
    echo "用法：$0 <目录>..." >&2
    exit 64
fi

# Swift：可带属性（@testable、@_exported、@_spi(X)…）、访问级别和导入种类，模块路径以 CSysPrivate 开头。
swift_import='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?CSysPrivate([[:space:].;]|$)'
# C / Objective-C：#include、#import、@import。
c_import='^[[:space:]]*(#[[:space:]]*(include|import)[[:space:]]*[<"]([^">]*/)?CSysPrivate(\.h)?[">]|@import[[:space:]]+CSysPrivate([[:space:].;]|$))'

status=0
for dir in "$@"; do
    if [ ! -d "$dir" ]; then
        echo "error: 私有层隔离检查：目录不存在：$dir" >&2
        exit 2
    fi

    matches="$(grep -rnE --include='*.swift' "$swift_import" "$dir")"
    rc=$?
    if [ "$rc" -gt 1 ]; then echo "error: 私有层隔离检查：读取 $dir 失败" >&2; exit 2; fi
    c_matches="$(grep -rnE --include='*.h' --include='*.c' --include='*.m' --include='*.mm' --include='*.pch' "$c_import" "$dir")"
    rc=$?
    if [ "$rc" -gt 1 ]; then echo "error: 私有层隔离检查：读取 $dir 失败" >&2; exit 2; fi

    if [ -n "$matches$c_matches" ]; then
        # 按 Xcode 能识别的「文件:行: error: 说明」格式输出，IDE 里可直接跳转。
        printf '%s\n%s\n' "$matches" "$c_matches" | sed '/^$/d' | while IFS= read -r hit; do
            file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"
            echo "$file:$line: error: 禁止在这里 import CSysPrivate：私有 API 只能经 SysCollectors 封装使用（D05、D23）"
        done
        status=1
    fi
done
exit "$status"
