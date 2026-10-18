#!/bin/zsh
# remote.sh - 把本目录探针同步到 Mac Studio 并在远端编译/运行（D18：只写 /tmp/sysinfo-cpu-research/processes/）。
# 用法：./remote.sh sync | ./remote.sh build <name.c|name.swift> [额外编译参数] | ./remote.sh run '<命令>'
set -e
HOST=${REMOTE_HOST:?set REMOTE_HOST=user@host}
R=/tmp/sysinfo-cpu-research/processes
ENV="HOME=$R/home CFFIXED_USER_HOME=$R/home TMPDIR=$R/tmp"
case "$1" in
  sync) rsync -a --include='*.c' --include='*.h' --include='*.swift' --include='*.sh' --exclude='*' ./ $HOST:$R/src/ ;;
  build)
    src=$2; shift 2; name=${src%.*}
    if [[ $src == *.swift ]]; then
      ssh -o BatchMode=yes $HOST "cd $R/src && env $ENV xcrun swiftc -O -module-cache-path $R/mc $* -o $R/bin/$name $src"
    else
      ssh -o BatchMode=yes $HOST "cd $R/src && env $ENV xcrun clang -O1 -Wall -fmodules-cache-path=$R/mc $* -o $R/bin/$name $src"
    fi ;;
  run) shift; ssh -o BatchMode=yes $HOST "cd $R/bin && env $ENV zsh -c '$*'" ;;
esac
