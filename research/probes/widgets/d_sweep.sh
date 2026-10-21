#!/bin/zsh
# probe D：逐档改快照参数（点数、填充大小、扩展内存负担），每档等一次刷新再截图。
# 依赖：dev host 已在运行且带 --reload-every 60（每档最多等 75 s 被刷新）。
# 用法：d_sweep.sh <截图目录>
set -u
here=${0:A:h}
app=$here/out/dev/SysInfoProbe.app
shots=${1:?shot dir}
mkdir -p $shots
step() {
  local tag=$1; shift
  echo "$(date '+%T') step $tag: $*"
  # 第二个 host 实例只写一次快照就退出；常驻的 host 之后沿用这些参数
  open -n $app --args --interval 0 --exit-after 3 "$@"
  sleep 75
  screencapture -x $shots/D-$tag.png
}
step points1440 --points 1440 --pad-kb 0 --ballast-mb 0
step pad1M --pad-kb 1024
step pad10M --pad-kb 10240
step pad0 --pad-kb 0
step ballast30 --ballast-mb 30
step ballast60 --ballast-mb 60
step ballast120 --ballast-mb 120
step ballast250 --ballast-mb 250
step reset --points 60 --pad-kb 0 --ballast-mb 0
echo "$(date '+%T') done"
