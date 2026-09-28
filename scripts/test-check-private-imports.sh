#!/bin/bash
# check-private-imports.sh 的回归样例（D05、D23）。make test / test-hw 会先跑它。
#
# 每个样例写进临时目录下单独的子目录，分别断言检查脚本的退出码：
# - 1：应当命中（各种能被编译器接受的引用写法）；
# - 0：不应命中（注释、字符串里提到 CSysPrivate）；
# - 2：目录不存在（fail closed）。
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check-private-imports.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-private-imports.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

failures=0
total=0

# expect <期望退出码> <样例名> <文件名> <内容>
expect() {
    local want="$1" name="$2" file="$3" content="$4"
    local dir="$work/case$total"
    total=$((total + 1))
    mkdir -p "$dir"
    printf '%s\n' "$content" >"$dir/$file"
    "$script" "$dir" >/dev/null 2>&1
    local got=$?
    if [ "$got" -ne "$want" ]; then
        echo "✗ ${name}：期望退出码 ${want}，实际 ${got}" >&2
        failures=$((failures + 1))
    fi
}

# --- 应当命中 ---
expect 1 "普通 import" a.swift 'import CSysPrivate'
expect 1 "访问级别" a.swift 'internal import CSysPrivate'
expect 1 "属性" a.swift '@preconcurrency import CSysPrivate'
expect 1 "带参数的属性" a.swift '@_spi(Private) @testable import CSysPrivate'
expect 1 "导入种类与子模块" a.swift 'import struct CSysPrivate.foo'
expect 1 "同一行分号" a.swift 'import Foundation; import CSysPrivate'
expect 1 "行首块注释" a.swift '/* x */ import CSysPrivate'
expect 1 "多行块注释结束后" a.swift $'/*\n x\n */ import CSysPrivate'
expect 1 "嵌套块注释结束后" a.swift $'/* a /* b */ c */ import CSysPrivate'
expect 1 "字符串之后" a.swift 'let s = "x"; import CSysPrivate'
expect 1 "多行字符串之后" a.swift $'let s = """\n  import CSysPrivate\n  """\nimport CSysPrivate'
expect 1 "import 与模块名分两行" a.swift $'import\n  CSysPrivate'
expect 1 "限定名引用" a.swift 'let v = CSysPrivate.csp_layer_version()'
expect 1 "C #include" a.c '#include "CSysPrivate.h"'
expect 1 "C #include 带路径" a.h '#  include <CSysPrivate/CSysPrivate.h>'
expect 1 "ObjC #import" a.m '#import "CSysPrivate.h"'
expect 1 "ObjC @import" a.m '@import CSysPrivate;'
expect 1 "C 注释之后" a.c '/* x */ #include "CSysPrivate.h"'
expect 1 "C 字符串里的 // 不算注释" a.c 'const char *s = "//"; @import CSysPrivate;'

# --- 不应命中 ---
expect 0 "行注释" a.swift '// import CSysPrivate'
expect 0 "文档注释" a.swift '/// 私有层 CSysPrivate 只在 SysCollectors 里用'
expect 0 "行尾注释" a.swift 'import Foundation // 不要 import CSysPrivate'
expect 0 "块注释" a.swift '/* import CSysPrivate */'
expect 0 "多行块注释" a.swift $'/*\n import CSysPrivate\n */'
expect 0 "嵌套块注释" a.swift $'/* a /* import CSysPrivate */ import CSysPrivate */'
expect 0 "字符串" a.swift 'let s = "import CSysPrivate"'
expect 0 "带转义的字符串" a.swift 'let s = "\"CSysPrivate\""'
expect 0 "多行字符串" a.swift $'let s = """\n  import CSysPrivate\n  """'
expect 0 "相似的标识符" a.swift 'import CSysPrivateTools'
expect 0 "C 注释" a.c '// #include "CSysPrivate.h"'
expect 0 "C 块注释" a.c $'/*\n#include "CSysPrivate.h"\n*/'
expect 0 "其他扩展名不检查" a.txt 'import CSysPrivate'

# --- 目录不存在：fail closed ---
"$script" "$work/does-not-exist" >/dev/null 2>&1
if [ $? -ne 2 ]; then
    echo "✗ 目录不存在时应当返回 2" >&2
    failures=$((failures + 1))
fi
total=$((total + 1))

if [ "$failures" -ne 0 ]; then
    echo "私有层隔离检查的回归样例：$failures / $total 个失败" >&2
    exit 1
fi
echo "私有层隔离检查的回归样例：$total 个全部通过"
