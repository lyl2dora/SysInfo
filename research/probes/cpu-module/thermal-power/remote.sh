#!/bin/zsh
# remote.sh — 把本目录源码同步到 Mac Studio 的 /tmp/sysinfo-cpu-research/thermal-power/src，并在受限环境里执行命令。
# 用法：./remote.sh sync | ./remote.sh run '<远端命令>'   （远端命令在 src 目录执行，HOME/TMPDIR/模块缓存都在 /tmp 下）
set -e
HOST=${REMOTE_HOST:-user@remote-host}
R=/tmp/sysinfo-cpu-research/thermal-power
here=${0:A:h}
case "$1" in
  sync) rsync -a --include='*.c' --include='*.h' --include='*.m' --include='*.swift' --include='*.sh' --exclude='*' "$here/" "$HOST:$R/src/" ;;
  run)  shift; ssh -o BatchMode=yes "$HOST" "export HOME=$R/home CFFIXED_USER_HOME=$R/home TMPDIR=$R/tmp; export MC=$R/mc CC_MC=-fmodules-cache-path=$R/mc; cd $R/src && $*" ;;
  *) echo "usage: $0 sync|run CMD"; exit 2 ;;
esac
