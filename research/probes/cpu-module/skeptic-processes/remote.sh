#!/bin/zsh
# remote.sh - skeptic-processes 复核探针：同步到 Mac Studio，在远端编译/运行。只写 /tmp/sysinfo-cpu-research/skeptic-processes/（D18）。
# 用法：./remote.sh sync | ./remote.sh build <x.c> | ./remote.sh run '<命令>'
set -e
HOST=${REMOTE_HOST:?set REMOTE_HOST=user@host}
R=/tmp/sysinfo-cpu-research/skeptic-processes
ENV="HOME=$R/home CFFIXED_USER_HOME=$R/home TMPDIR=$R/tmp"
cd "${0:A:h}"
case "$1" in
  sync) ssh -o BatchMode=yes $HOST "mkdir -p $R/home $R/tmp $R/mc $R/src $R/bin"; rsync -a --include='*.c' --include='*.h' --include='*.sh' --exclude='*' ./ $HOST:$R/src/ ;;
  build) src=$2; name=${src%.*}; ssh -o BatchMode=yes $HOST "cd $R/src && env $ENV xcrun clang -O1 -Wall -fmodules-cache-path=$R/mc -o $R/bin/$name $src" ;;
  run) shift; ssh -o BatchMode=yes $HOST "cd $R/bin && env $ENV zsh -c '$*'" ;;
esac
