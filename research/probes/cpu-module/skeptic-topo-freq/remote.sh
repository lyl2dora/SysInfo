#!/bin/zsh
# 在 Mac Studio 上编译并运行本目录的 C 探针（D18：远端只写 /tmp/sysinfo-cpu-research/skeptic-topo-freq）。
# 用法：./remote.sh <probe.c> [运行参数...]
set -e
HOST=${REMOTE_HOST:?set REMOTE_HOST=user@host}
R=/tmp/sysinfo-cpu-research/skeptic-topo-freq
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 $HOST)
src=$1; shift
name=${src:t:r}
"${SSH[@]}" "mkdir -p $R/home $R/tmp $R/mc $R/src $R/bin"
rsync -a -e "ssh -o BatchMode=yes" ${src:h}/sk.h $src $HOST:$R/src/
ENV="HOME=$R/home CFFIXED_USER_HOME=$R/home TMPDIR=$R/tmp"
"${SSH[@]}" "cd $R/src && env $ENV clang -O2 -Wall -Wno-unused -fmodules-cache-path=$R/mc -o $R/bin/$name ${src:t} -framework IOKit -framework CoreFoundation -lIOReport && env $ENV $R/bin/$name $*"
