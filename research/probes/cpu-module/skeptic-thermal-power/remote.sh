#!/bin/zsh
# remote.sh — skeptic-thermal-power：把本目录 .c/.h/.swift 同步到 Mac Studio 的 /tmp/sysinfo-cpu-research/skeptic-thermal-power/src 并在受限环境下执行。
# 用法：./remote.sh sync | ./remote.sh build | ./remote.sh run '<命令>'
set -e
HOST=${REMOTE_HOST:?set REMOTE_HOST=user@host}
R=/tmp/sysinfo-cpu-research/skeptic-thermal-power
here=${0:A:h}
ENV="export HOME=$R/home CFFIXED_USER_HOME=$R/home TMPDIR=$R/tmp; mkdir -p $R/home $R/tmp $R/mc $R/bin $R/out; cd $R/src"
case "$1" in
  sync)  ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "mkdir -p $R/src"; rsync -a --include='*.c' --include='*.h' --include='*.swift' --exclude='*' "$here/" "$HOST:$R/src/" ;;
  build) ssh -o BatchMode=yes "$HOST" "$ENV; for f in sk_rec sk_cost sk_em_watch sk_em_struct; do clang -O2 -fmodules-cache-path=$R/mc -o $R/bin/\$f \$f.c -framework IOKit -framework CoreFoundation -lIOReport || exit 1; done; swiftc -O -module-cache-path $R/mc -o $R/bin/sk_thermal_cost sk_thermal_cost.swift; ls $R/bin" ;;
  run)   shift; ssh -o BatchMode=yes "$HOST" "$ENV; $*" ;;
  *) echo "usage: $0 sync|build|run CMD"; exit 2 ;;
esac
