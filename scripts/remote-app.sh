#!/bin/bash
# 在对照机上构建、启动、截图并清场 Debug 版 SysInfo Dev（D39：截图自查用，用完清场）。
#
# 用法（由 Makefile 的 remote-app-* 目标调用，也可以直接用）：
#   scripts/remote-app.sh build                 同步源码到远端 /tmp/sysinfo-remote/repo 并 xcodebuild（DerivedData 也在 /tmp；
#                                               ad-hoc 签名，不用远端钥匙串）
#   scripts/remote-app.sh run [app 参数…]        启动（总是带 --factory-defaults，TMPDIR 指向 /tmp/sysinfo-remote/tmp）
#   scripts/remote-app.sh shot <本地 png> [滚动位置 0…1]
#                                               截 SysInfo Dev 的窗口（面板或设置窗口），取回本地
#   scripts/remote-app.sh clean                 结束 app，取消 LaunchServices 登记，删掉这次运行新留下的家目录痕迹
#
# 远端只结束自己启动的 SysInfo Dev（按可执行文件路径匹配，D18）。清场只删「启动前不存在」的路径（启动时记一份清单）。
set -euo pipefail

host="${REMOTE_HOST:-user@remote-host}"
dir="/tmp/sysinfo-remote"
ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host")
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$dir/dd/Build/Products/Debug/SysInfo.app"
env_vars="CFFIXED_USER_HOME=$dir/home HOME=$dir/home TMPDIR=$dir/tmp"
# 启动 GUI app 后可能出现的家目录痕迹（D39）。
traces=(
    "Library/Saved Application State/zone.lyl.sysinfo.dev.savedState"
    "Library/Preferences/zone.lyl.sysinfo.dev.plist"
    "Library/Caches/zone.lyl.sysinfo.dev"
    "Library/HTTPStorages/zone.lyl.sysinfo.dev"
    "Library/Application Support/zone.lyl.sysinfo.dev"
)

remote() { "${ssh_cmd[@]}" "$@"; }

case "${1:-}" in
build)
    remote "mkdir -p $dir/repo $dir/tmp $dir/home"
    rsync -a --delete --exclude .git --exclude build --exclude .build --exclude .swiftpm -e "ssh -o BatchMode=yes" \
        "$repo_root/App" "$repo_root/Config" "$repo_root/Packages" "$repo_root/SysInfo.xcodeproj" "$repo_root/scripts" \
        "$host:$dir/repo/"
    remote "cd $dir/repo && $env_vars xcodebuild -project SysInfo.xcodeproj -scheme SysInfo -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $dir/dd CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build 2>&1 | grep -E ' error: |^\*\* ' | tail -5"
    ;;
run)
    shift
    # 记下启动前已存在的痕迹，清场时不动它们。
    list=""
    for t in "${traces[@]}"; do list+="\"\$HOME/$t\" "; done
    remote "for p in $list; do [ -e \"\$p\" ] && echo \"\$p\"; done > $dir/preexisting.txt; true"
    remote "open -n --env TMPDIR=$dir/tmp '$app' --args --factory-defaults $*"
    ;;
shot)
    out="${2:?需要本地输出路径}"
    pos="${3:-}"
    rsync -a -e "ssh -o BatchMode=yes" "$repo_root/scripts/window-shot.swift" "$host:$dir/window-shot.swift"
    remote "cd $dir && $env_vars swift window-shot.swift $dir/shot.png $pos 2>&1 | tail -2"
    rsync -a -e "ssh -o BatchMode=yes" "$host:$dir/shot.png" "$out"
    remote "rm -f $dir/shot.png"
    ;;
clean)
    # /tmp 是 /private/tmp 的链接，进程的可执行文件路径是 /private/tmp/…，两种写法都要匹配。
    exe_pattern="^(/private)?$app/Contents/MacOS/SysInfo( |\$)"
    remote "pids=\$(pgrep -f '$exe_pattern' || true); if [ -n \"\$pids\" ]; then echo \"结束 SysInfo Dev：\$(echo \$pids | tr '\\n' ' ')\"; echo \"\$pids\" | xargs kill -TERM; sleep 2; fi; true"
    remote "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u '$app' 2>/dev/null; true"
    list=""
    for t in "${traces[@]}"; do list+="\"\$HOME/$t\" "; done
    remote "touch $dir/preexisting.txt; for p in $list; do if [ -e \"\$p\" ] && ! grep -qxF \"\$p\" $dir/preexisting.txt; then rm -rf \"\$p\" && echo \"删除 \$p\"; fi; done; true"
    remote "defaults read zone.lyl.sysinfo.dev >/dev/null 2>&1 && ! grep -q Preferences $dir/preexisting.txt && defaults delete zone.lyl.sysinfo.dev && echo '删除偏好域 zone.lyl.sysinfo.dev'; true"
    ;;
*)
    sed -n '2,13p' "$0"
    exit 64
    ;;
esac
