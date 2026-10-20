#!/bin/bash
# exp.sh <app 路径> <输出文件>：两条排序路线的全套实验，本机与对照机跑同一份（docs/design/menubar-order.md §3）。
# 每个 run 是 mborder 的一次启动（= 一次 app 重启）；名字按路线分组，各路线开头都是「从没被记住过」的新名字。
# 输出只含本 app 的 item 顺序、菜单栏全局顺序（其他 app 以序号代替）和本域的 NSStatusItem* 键，不含设备标识。
set -u
app="${1:?app}"
out="${2:?out}"
bin="$app/Contents/MacOS/mborder"
bin2="$(dirname "$app")/mborder2.app/Contents/MacOS/mborder"
here="$(cd "$(dirname "$0")" && pwd)"
tag="${TAG:-$(date +%H%M%S)}"   # 每次完整实验换一组名字，避免上一次的记忆干扰
: > "$out"

run() { # run <标签> <步骤>
    echo "### $1" | tee -a "$out"
    # 自带看门狗：60 s 内没结束就只结束这个 probe 进程；看门狗的输出不接进管道，免得拖住 grep。
    "$bin" --steps "$2" > "$out.run" 2>&1 & local pid=$!
    ( sleep 60; kill "$pid" 2>/dev/null && echo "WATCHDOG killed $pid" >> "$out.run" ) > /dev/null 2>&1 & local wdp=$!
    wait "$pid"; kill "$wdp" 2>/dev/null; wait "$wdp" 2>/dev/null
    grep -E "own L|bar L|own keys|nil autosave|prefslots|slots saved|drag |removed|---- report|usage|unknown|WATCHDOG" "$out.run" | tee -a "$out"
    rm -f "$out.run"
}

# 名字：n 路线 n<tag>a…；p 路线 p<tag>a…。AX 标题是按钮标题的小写，和名字一致。
A=n${tag}a; B=n${tag}b; C=n${tag}c; M=n${tag}m
W="wait:1.5"

echo "## 路线 N：autosaveName = nil 清位置后按顺序重建" | tee -a "$out"
run N0-fresh            "clear;create:$A,$B,$C;$W;report:N0"
run N1-drag-a-leftmost  "create:$A,$B,$C;$W;report:N1-before;drag:$A>$C;$W;report:N1-after"
run N2-relaunch-memory  "create:$C,$B,$A;$W;report:N2"
# 目标左→右 B A C：后创建的在左，所以按 C、A、B 的顺序创建
run N3-nil-rebuild      "create:$A,$B,$C;$W;report:N3-start;nil:$A,$B,$C;$W;report:N3-after-nil;remove:all;create:$C,$A,$B;$W;report:N3-rebuilt"
run N4a-relaunch-target "create:$C,$A,$B;$W;report:N4a"
run N4b-relaunch-other  "create:$A,$B,$C;$W;report:N4b"
run N5-merge-roundtrip  "create:$C,$A,$B;$W;report:N5-split;remove:all;create:$M;$W;report:N5-merged;remove:all;create:$C,$A,$B;$W;report:N5-split-again"
# 用户再 ⌘ 拖动一次：系统重新记住；再用 nil 清一次，看能否重复
run N6-drag-again       "create:$C,$A,$B;$W;report:N6-before;drag:$C>$B;$W;report:N6-after"
run N7-relaunch-memory  "create:$C,$A,$B;$W;report:N7"
run N8-nil-again        "create:$C,$A,$B;$W;nil:$A,$B,$C;remove:all;create:$B,$C,$A;$W;report:N8-rebuilt"
run N9-relaunch         "create:$B,$C,$A;$W;report:N9"

A=p${tag}a; B=p${tag}b; C=p${tag}c; M=p${tag}m
echo "## 路线 P（对照）：未公开的 Preferred Position 键" | tee -a "$out"
run P0-fresh            "clear;create:$A,$B,$C;$W;report:P0"
# 目标左→右 B A C：按当前位置的槽位重新分配后写键，再移除重建（创建顺序保持 A,B,C 不变，看键是否压过创建顺序）
# P1：先写键再移除（看 removeStatusItem 会不会删键）；P1b：先移除、再写键、再创建
run P1-slots-then-remove "create:$A,$B,$C;$W;report:P1-start;prefslots:$B,$A,$C;report:P1-written;remove:all;report:P1-after-remove;create:$A,$B,$C;$W;report:P1-rebuilt"
run P1b-remove-then-slots "create:$A,$B,$C;$W;report:P1b-start;slots;remove:all;prefslots:$B,$A,$C;create:$A,$B,$C;$W;report:P1b-rebuilt"
run P2-relaunch         "create:$A,$B,$C;$W;report:P2"
run P3-drag             "create:$A,$B,$C;$W;report:P3-before;drag:$C>$B;$W;report:P3-after"
run P4-relaunch-memory  "create:$A,$B,$C;$W;report:P4"
run P5-slots-vs-memory  "create:$A,$B,$C;$W;slots;remove:all;prefslots:$B,$A,$C;create:$A,$B,$C;$W;report:P5"
run P6-nil-then-slots   "create:$A,$B,$C;$W;nil:$A,$B,$C;remove:all;create:$A,$B,$C;$W;slots;remove:all;prefslots:$B,$A,$C;create:$A,$B,$C;$W;report:P6"
run P7-relaunch         "create:$A,$B,$C;$W;report:P7"
run P8-merge-roundtrip  "create:$A,$B,$C;$W;report:P8-split;remove:all;create:$M;$W;report:P8-merged;remove:all;create:$A,$B,$C;$W;report:P8-split-again"

A1=r${tag}a1; B1=r${tag}b1; C1=r${tag}c1; A2=r${tag}a2; B2=r${tag}b2; C2=r${tag}c2; A3=r${tag}a3; B3=r${tag}b3; C3=r${tag}c3
echo "## 路线 R：换一组从没被记住过的 autosaveName 再按顺序重建" | tee -a "$out"
run R0-fresh-gen1        "create:$A1,$B1,$C1;$W;report:R0"
run R1-drag-gen1         "create:$A1,$B1,$C1;$W;drag:$A1>$C1;$W;report:R1-after"
run R2-relaunch-memory   "create:$A1,$B1,$C1;$W;report:R2"
# 目标左→右 B A C：换成第 2 代名字，按 C、A、B 的顺序创建
run R3-rotate-runtime    "create:$A1,$B1,$C1;$W;report:R3-start;remove:all;create:$C2,$A2,$B2;$W;report:R3-rebuilt"
run R4a-relaunch-target  "create:$C2,$A2,$B2;$W;report:R4a"
run R4b-relaunch-other   "create:$A2,$B2,$C2;$W;report:R4b"
run R5-toggle-one        "create:$C2,$A2,$B2;$W;remove:$A2;$W;report:R5-off;create:$A2;$W;report:R5-on;remove:all;create:$C2,$A2,$B2;$W;report:R5-rebuilt"
# 其他 app：第二个 probe 先放一个 item（xo），再看本 app 的一组怎么摆、拖过它之后再换代重建会怎样
"$bin2" --steps "create:xo;wait:50" > /dev/null 2>&1 & xpid=$!
sleep 1.5
run R6-with-other        "create:$C2,$A2,$B2;$W;report:R6-start;dragby:$C2=75;$W;report:R6-dragged-past;remove:all;create:$C3,$A3,$B3;$W;report:R6-rotated"
run R7-relaunch-gen2     "create:$C2,$A2,$B2;$W;report:R7-gen2-memory"
run R8-relaunch-gen3     "create:$C3,$A3,$B3;$W;report:R8-gen3"
kill $xpid 2>/dev/null; wait $xpid 2>/dev/null

echo "## 收尾：清掉本次所有名字的记忆与键" | tee -a "$out"
# nil 清不掉系统的位置记忆（N3），这里只清本域的键；系统里残留的是 local.probe.mborder 的条目，与 SysInfo 无关
run Z-cleanup "clear;report:Z"
