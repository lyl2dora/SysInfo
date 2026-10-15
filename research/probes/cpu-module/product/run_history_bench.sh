#!/bin/zsh
# 跑 history_bench 的配置矩阵（CPU 模块产品方案 · 历史存储估算）。
# 用法：run_history_bench.sh <临时目录> [输出文件]
# 数据库写在临时目录里，每个配置跑完即删；只用系统 libsqlite3，不访问硬件数据源。
set -eu
tmp=${1:?临时目录}
out=${2:-/dev/stdout}
here=${0:A:h}
mkdir -p "$tmp"
xcrun clang -O2 -Wall "$here/history_bench.c" -lsqlite3 -o "$tmp/history_bench"
{
  echo "# history_bench $(date '+%F %T') $(sysctl -n hw.model) $(sw_vers -buildVersion)"
  # 写入放大：布局 × 每分钟系统行数（12 = 仅 CPU；80 = 估计的 P0 全部模块）× 提交间隔，模拟 3 天
  for layout in A B C; do
    for metrics in 12 80; do
      for every in 1 5 15; do
        echo "== layout=$layout metrics=$metrics apps=10 every=$every days=3"
        "$tmp/history_bench" "$tmp/h.sqlite" $layout $metrics 10 $every 3 | grep -v '^config\|^sqlite_version'
        rm -f "$tmp/h.sqlite" "$tmp/h.sqlite-wal" "$tmp/h.sqlite-shm"
      done
    done
  done
  # 占用：30 天，推荐布局
  for layout in A B C; do
    echo "== size layout=$layout metrics=80 apps=10 every=5 days=30"
    "$tmp/history_bench" "$tmp/h.sqlite" $layout 80 10 5 30 | grep -v '^config'
    rm -f "$tmp/h.sqlite" "$tmp/h.sqlite-wal" "$tmp/h.sqlite-shm"
  done
  echo "== size layout=B metrics=12 apps=0 every=5 days=30"
  "$tmp/history_bench" "$tmp/h.sqlite" B 12 0 5 30 | grep -v '^config'
  rm -f "$tmp/h.sqlite" "$tmp/h.sqlite-wal" "$tmp/h.sqlite-shm"
  echo "== size layout=B metrics=0 apps=10 every=5 days=30"
  "$tmp/history_bench" "$tmp/h.sqlite" B 0 10 5 30 | grep -v '^config'
  rm -f "$tmp/h.sqlite" "$tmp/h.sqlite-wal" "$tmp/h.sqlite-shm"
} > "$out"
