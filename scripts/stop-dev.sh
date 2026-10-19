#!/bin/bash
# 结束本仓库构建出来、正在运行的 Debug 版 SysInfo Dev。
#
# D18：只结束自己派生的进程。这里只匹配可执行文件路径正好是本仓库 Debug 构建产物的进程，
# 不碰 Release 版 SysInfo、从其他位置启动的实例、Stats 或用户的其他程序。
#
# 用法：scripts/stop-dev.sh [app 路径]，默认为 build/DerivedData/Build/Products/Debug/SysInfo.app
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$repo_root/build/DerivedData/Build/Products/Debug/SysInfo.app}"
exe_path="$(cd "$(dirname "$app_path")" 2>/dev/null && pwd)/$(basename "$app_path")/Contents/MacOS/SysInfo"

# 文件系统不区分大小写，LaunchServices 记录的路径大小写可能与这里不同，所以用 -i。
# 转义正则元字符，只做整条路径匹配（后面允许跟参数）。
pattern="^$(printf '%s' "$exe_path" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"

# 小组件扩展（D90）由 chronod 拉起，app 重新构建后它还跑着旧代码，所以一并结束（同样只匹配本仓库 Debug 构建的扩展路径）。
# 下次刷新时 chronod 会用新的二进制重新拉起它。
ext_path="$(dirname "$exe_path")/../PlugIns/SysInfoWidgets.appex/Contents/MacOS/SysInfoWidgets"
ext_path="$(cd "$(dirname "$ext_path")" 2>/dev/null && pwd)/SysInfoWidgets" || true
ext_pattern="^$(printf '%s' "$ext_path" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"
ext_pids="$(pgrep -i -f "$ext_pattern" || true)"
if [ -n "$ext_pids" ]; then
    echo "结束 SysInfo Dev 的小组件扩展：pid $(echo $ext_pids)"
    kill -TERM $ext_pids 2>/dev/null || true
fi

pids="$(pgrep -i -f "$pattern" || true)"
if [ -z "$pids" ]; then
    exit 0
fi

echo "结束 SysInfo Dev：pid $(echo $pids)"
kill -TERM $pids

# 最多等 5 秒；仍未退出的再发 SIGKILL（仍然只针对上面匹配到的自有进程）。
for _ in $(seq 50); do
    remaining=""
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then remaining="$remaining $pid"; fi
    done
    [ -z "$remaining" ] && exit 0
    sleep 0.1
done
echo "SysInfo Dev 未在 5 秒内退出，发送 SIGKILL：pid$remaining" >&2
kill -KILL $remaining 2>/dev/null || true
