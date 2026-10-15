#!/bin/bash
# 自身开销测量（M0 设计 §9、CPU 模块设计 §10，K26、D19、D18）。
#
# 用 Release 配置构建 app，按四档各测一次，结果追加到 docs/perf/cpu.md：
#   0. 基线：不运行 SysInfo；
#   1. 出厂默认配置：CPU 占用与整机功率两个 item（D38、D44），面板关闭，历史与能耗记录开启（--factory-defaults 时历史库在临时目录）；
#   2. 面板打开：CPU tab 可见（含 Top N 5 行），固定为浮窗（--open-panel --pin-panel），测量期间点别处也不会关；
#   3. 面板打开且「详情」「中断来源」展开（再加 --expand-details），面板内最重的一档；
#   power：面板打开且在「功耗与散热」tab（--panel-tab=power，功耗与散热模块设计 §1 第 8 项）。
# 每档先预热 WARMUP 秒，再测 DURATION 秒。考核值按 D40：用 sysinfo-cli rusage 读 app 的按档计数，把其他档的指令
# 折算成最快档的等效时间（按单核的比例）；`ps -o time=` 的原始 CPU 时间、按周期折算的值、能耗一并记录；
# 同一时段 MenuBarAgent、WindowServer 的 CPU 增量作为软指标，另测一段不运行 SysInfo 的基线作对照。
#
# 操作边界（D18、D16）：
# - Stats 在运行时直接拒绝执行，请用户手动退出；脚本不结束 Stats。
# - 已有 SysInfo 实例在运行时也拒绝执行（Debug 版可用 make stop 结束）。
# - 只结束本脚本自己启动的 app 进程。
# - 构建产物用 Release 配置（优化后的代码），但 Bundle ID 改成 .dev、显示名 SysInfo Dev，
#   并带 --factory-defaults 启动（不读写偏好）：测量不碰日用版 zone.lyl.sysinfo 的 defaults 域。
#
# 环境变量：WARMUP（默认 30）、DURATION（默认 120）、BASELINE（默认 1；0 表示不测基线）、
#          OUTPUT（默认 docs/perf/cpu.md）、TIERS（默认 "default panel details"，可只测其中几档；另有 power 档）。
# 对照机（make remote-measure，D39）另设：REMOTE_MODE=1（ad-hoc 签名；用 `open` 启动，ssh 会话里直接 exec 的
#          GUI app 连不上窗口服务器）、DERIVED_DATA、GIT_COMMIT、BUILD_NUMBER（远端没有 .git）、APP_TMPDIR。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repo_root}"

WARMUP="${WARMUP:-30}"
DURATION="${DURATION:-120}"
BASELINE="${BASELINE:-1}"
OUTPUT="${OUTPUT:-docs/perf/cpu.md}"
REMOTE_MODE="${REMOTE_MODE:-0}"

derived_data="${DERIVED_DATA:-build/MeasureDerivedData}"
app="${derived_data}/Build/Products/Release/SysInfo.app"
exe="${app}/Contents/MacOS/SysInfo"

# ---------------------------------------------------------------- 前置检查

if pgrep -x Stats >/dev/null 2>&1; then
    echo "检测到 Stats 正在运行（pid $(pgrep -x Stats | tr '\n' ' ')）。" >&2
    echo "开销测量要求环境干净：请手动退出 Stats 后再运行 make measure。脚本不会去结束它（D18、K26）。" >&2
    exit 2
fi

existing="$(pgrep -f '/SysInfo\.app/Contents/MacOS/SysInfo( |$)' || true)"
if [ -n "${existing}" ]; then
    echo "已有 SysInfo 在运行（pid $(echo ${existing})），会干扰 MenuBarAgent/WindowServer 的对照。" >&2
    echo "请先退出它（本仓库的 Debug 版可用 make stop）。" >&2
    exit 2
fi

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# ps -o time= 的输出（[dd-][hh:]mm:ss.cc）→ 秒
cpu_seconds() {
    local raw
    raw="$(ps -o time= -p "$1" 2>/dev/null | tr -d ' ')" || return 1
    [ -n "${raw}" ] || return 1
    perl -e '
        my $t = shift; my $days = 0;
        if ($t =~ s/^(\d+)-//) { $days = $1 }
        my @f = split /:/, $t; my $s = 0;
        $s = $s * 60 + $_ for @f;
        printf "%.2f\n", $s + $days * 86400;
    ' "${raw}"
}

system_pid() { pgrep -x "$1" | head -1; }

percent() { perl -e 'printf "%.3f", ($ARGV[1] - $ARGV[0]) / $ARGV[2] * 100' "$1" "$2" "$3"; }

# ---------------------------------------------------------------- 构建

build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
git_commit="${GIT_COMMIT:-$(git rev-parse --short HEAD)$(git diff --quiet HEAD 2>/dev/null || echo -dirty)}"
sign_args=()
if [ "${REMOTE_MODE}" = "1" ]; then
    sign_args=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

echo "==> 构建 Release 配置（Bundle ID 改为 zone.lyl.sysinfo.dev）"
xcodebuild -project SysInfo.xcodeproj -scheme SysInfo -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "${derived_data}" \
    CURRENT_PROJECT_VERSION="${build_number}" SYSINFO_GIT_COMMIT="${git_commit}" \
    PRODUCT_BUNDLE_IDENTIFIER=zone.lyl.sysinfo.dev INFOPLIST_KEY_CFBundleDisplayName="SysInfo Dev" \
    ${sign_args[@]+"${sign_args[@]}"} build -quiet
[ -x "${exe}" ] || { echo "构建产物不存在：${exe}" >&2; exit 1; }

# D40：读进程的按档计数（rusage_info_v6），把其他档的指令折算成最快档的等效时间。
echo "==> 构建 sysinfo-cli（读按档计数用）"
swift build -c release --package-path Packages/SysKit --product sysinfo-cli >/dev/null
cli="Packages/SysKit/.build/release/sysinfo-cli"
[ -x "${cli}" ] || { echo "sysinfo-cli 构建失败" >&2; exit 1; }

# ---------------------------------------------------------------- 测量

app_pid=""
stop_app() {
    [ -n "${app_pid}" ] || return 0
    kill -TERM "${app_pid}" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "${app_pid}" 2>/dev/null || break; sleep 0.1; done
    app_pid=""
}
cleanup() {
    if [ -n "${app_pid}" ] && kill -0 "${app_pid}" 2>/dev/null; then stop_app; fi
}

# 启动 app，设置 app_pid。本机直接 exec；对照机经 `open` 启动（进 GUI 会话），再按可执行文件路径找 pid。
launch_app() {
    if [ "${REMOTE_MODE}" = "1" ]; then
        local abs_exe
        abs_exe="$(cd "$(dirname "${exe}")" && pwd -P)/$(basename "${exe}")"
        open -n ${APP_TMPDIR:+--env TMPDIR="${APP_TMPDIR}"} "${app}" --args "$@"
        for _ in $(seq 50); do
            app_pid="$(pgrep -n -f "^${abs_exe}( |\$)" || true)"
            [ -n "${app_pid}" ] && break
            sleep 0.1
        done
        [ -n "${app_pid}" ] || { echo "找不到刚启动的 app 进程" >&2; exit 1; }
    else
        "${exe}" "$@" >/dev/null 2>&1 &
        app_pid=$!
    fi
}
# 被中断（Ctrl-C、kill）时立即退出、不写结果；退出时结束本脚本启动的 app。
trap cleanup EXIT
trap 'echo "测量被中断，不写结果" >&2; exit 130' INT TERM
# 前台 sleep 期间 bash 不处理信号，改为后台 sleep + wait，中断能立刻生效。
nap() { sleep "$1" & wait $!; }

mba_pid="$(system_pid MenuBarAgent)"
ws_pid="$(system_pid WindowServer)"

# 测一段：$1 = 标签，$2… = app 参数（label 为 baseline 时不启动 app）。
# 结果（标签 app% mba% ws% footprint 备注，制表符分隔）追加到 results 数组。
# 不在子 shell 里运行，这样中途中断时 EXIT trap 能结束本脚本启动的 app。
results=()
measure() {
    local label="$1"; shift
    local note=""
    app_pid=""
    if [ "${label}" != "baseline" ]; then
        launch_app "$@"
        echo "==> [${label}] 启动 pid ${app_pid}，参数：$*；预热 ${WARMUP}s" >&2
        nap "${WARMUP}"
        kill -0 "${app_pid}" 2>/dev/null || { echo "app 在预热期间退出了" >&2; exit 1; }
    else
        echo "==> [baseline] 不运行 SysInfo" >&2
    fi

    local t0 a0="" m0 w0 t1 a1="" m1 w1 r0="" r1=""
    t0="$(now)"
    [ -n "${app_pid}" ] && a0="$(cpu_seconds "${app_pid}")"
    [ -n "${app_pid}" ] && r0="$("${cli}" rusage --pid "${app_pid}" 2>/dev/null || true)"
    m0="$(cpu_seconds "${mba_pid}")"
    w0="$(cpu_seconds "${ws_pid}")"
    echo "    测量 ${DURATION}s …" >&2
    nap "${DURATION}"
    t1="$(now)"
    [ -n "${app_pid}" ] && a1="$(cpu_seconds "${app_pid}")"
    [ -n "${app_pid}" ] && r1="$("${cli}" rusage --pid "${app_pid}" 2>/dev/null || true)"
    m1="$(cpu_seconds "${mba_pid}")"
    w1="$(cpu_seconds "${ws_pid}")"

    local elapsed app_pct="—" footprint="—" equiv="—" cyc="—" p0share="—" mw="—"
    elapsed="$(perl -e 'printf "%.3f", $ARGV[1] - $ARGV[0]' "${t0}" "${t1}")"
    if [ -n "${app_pid}" ]; then
        app_pct="$(percent "${a0}" "${a1}" "${elapsed}")"
        if [ -n "${r0}" ] && [ -n "${r1}" ]; then
            # 输出：等效最快档 %、按周期折算 %、最快档时间占比 %、能耗 mW（D40）
            read -r equiv cyc p0share mw < <(perl -e '
                my ($a, $b, $sec) = @ARGV;
                my %x; my %y;
                %x = $a =~ /"(\w+)":(\d+)/g; %y = $b =~ /"(\w+)":(\d+)/g;
                my %d = map { $_ => $y{$_} - $x{$_} } grep { $_ ne "p0_top_hz" } keys %y;
                my $el = $sec * 1e9;
                my ($cpu, $p0, $i, $ip, $c, $cp) = @d{qw(cpu_ns p0_ns instructions p0_instructions cycles p0_cycles)};
                my $eq = "—"; my $cy = "—";
                my $top = $y{p0_top_hz} || 0;
                if ($p0 >= 20e6 && $ip > 0) { $eq = sprintf "%.3f", ($p0 + ($i - $ip) * $p0 / $ip) / $el * 100 }
                elsif ($top > 0) { $eq = sprintf "%.3f*", ($p0 + ($c - $cp) / $top * 1e9) / $el * 100 }
                if ($cp > 0 && $p0 > 0) { $cy = sprintf "%.3f", ($p0 + ($c - $cp) * $p0 / $cp) / $el * 100 }
                my $share = $cpu > 0 ? sprintf("%.0f", $p0 / $cpu * 100) : "—";
                printf "%s %s %s %.1f\n", $eq, $cy, $share, $d{energy_nj} / $sec / 1e6;
            ' "${r0}" "${r1}" "${elapsed}")
        fi
        footprint="$(/usr/bin/footprint -p "${app_pid}" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p' | head -1)"
        [ -n "${footprint}" ] || footprint="?"
        # 面板档：测量期间面板若被关闭（有人点了关闭按钮），这一档作废。
        if [ "${label}" = "panel" ] || [ "${label}" = "details" ]; then
            if /usr/bin/log show --last "$((WARMUP + DURATION + 30))s" --info --style compact \
                --predicate "processID == ${app_pid} AND category == \"panel\"" 2>/dev/null | grep -q "面板已隐藏"; then
                note="面板在测量期间被关闭，本档作废"
            fi
        fi
        stop_app
        sleep 3
    fi
    local mba_pct ws_pct
    mba_pct="$(percent "${m0}" "${m1}" "${elapsed}")"
    ws_pct="$(percent "${w0}" "${w1}" "${elapsed}")"
    echo "    app ${app_pct}%（等效最快档 ${equiv}%，按周期 ${cyc}%，最快档占比 ${p0share}%，${mw} mW）  MenuBarAgent ${mba_pct}%  WindowServer ${ws_pct}%  footprint ${footprint} ${note}" >&2
    results+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${label}" "${app_pct}" "${equiv}" "${cyc}" "${p0share}" "${mw}" "${mba_pct}" "${ws_pct}" "${footprint}" "${note}")")
}

echo "测量期间尽量不要操作鼠标和键盘（会抬高 WindowServer 等软指标）。面板档固定为浮窗，点别处不会关闭。" >&2
if [ "${BASELINE}" != "0" ]; then
    measure baseline
fi
TIERS="${TIERS:-default panel details}"
for tier in ${TIERS}; do
    case "${tier}" in
        default) measure default --factory-defaults ;;
        panel) measure panel --factory-defaults --open-panel --pin-panel ;;
        details) measure details --factory-defaults --open-panel --pin-panel --expand-details ;;
        power) measure power --factory-defaults --open-panel --pin-panel --panel-tab=power ;;
        *) echo "未知档位：${tier}" >&2; exit 64 ;;
    esac
done

# ---------------------------------------------------------------- 写结果

model="$(sysctl -n hw.model)"
chip="$(sysctl -n machdep.cpu.brand_string)"
ncpu="$(sysctl -n hw.logicalcpu)"
os="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
date_str="$(date '+%Y-%m-%d %H:%M')"

mkdir -p "$(dirname "${OUTPUT}")"
if [ ! -f "${OUTPUT}" ]; then
    cat >"${OUTPUT}" <<'EOF'
# SysInfo 自身开销测量

> 由 `make measure` / `make remote-measure`（`scripts/measure-overhead.sh`）追加，口径见 M0 设计 §9、CPU 模块设计 §10、K26：
> - 「app」是 SysInfo 进程的 CPU 占用，按单核的比例（100% = 占满一个核），由 `ps -o time=` 的差值算出；
> - MenuBarAgent、WindowServer 是同一时段的 CPU 增量，是软指标：它们也在为其他 app 工作，要和「基线」（不运行 SysInfo）对照看；
> - 构建为 Release 配置，Bundle ID 改为 `.dev` 并带 `--factory-defaults` 启动，不碰日用版的偏好（D16、D18）；
> - 目标（D19 出厂默认配置）：默认 < 0.5%，面板打开 < 2%。
EOF
fi

{
    echo ""
    echo "## ${date_str} · ${git_commit}（build ${build_number}）"
    echo ""
    echo "- 机器：${model}，${chip}，${ncpu} 个逻辑核，macOS ${os}"
    echo "- 预热 ${WARMUP} s，每档测量 ${DURATION} s"
    echo ""
    echo "| 档位 | app 等效最快档（单核 %，D40 考核值） | app 原始 CPU（单核 %） | 按周期折算（%） | 最快档时间占比 | app 能耗（mW） | MenuBarAgent（%） | WindowServer（%） | app footprint | 备注 |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    for row in "${results[@]}"; do
        IFS=$'\t' read -r label app_pct equiv cyc p0share mw mba_pct ws_pct footprint note <<<"${row}"
        case "${label}" in
            baseline) name="基线（不运行 SysInfo）" ;;
            default) name="出厂默认（CPU 占用、整机功率两个 item，面板关闭，历史与能耗开启）" ;;
            panel) name="面板打开（CPU tab，Top N 5 行）" ;;
            details) name="面板打开 + 详情与中断来源展开" ;;
            power) name="面板打开（功耗与散热 tab）" ;;
            *) name="${label}" ;;
        esac
        echo "| ${name} | ${equiv} | ${app_pct} | ${cyc} | ${p0share}% | ${mw} | ${mba_pct} | ${ws_pct} | ${footprint} | ${note:-} |"
    done
    echo ""
    echo "考核值按 D40 折算成最快档等效时间；带 * 的是最快档时间太少（< 20 ms），按「周期数 ÷ 最快档顶档频率」估算：能效核 IPC 较低会让它偏高，假设最快档跑在顶档频率又会让它偏低，只作估算。"
} >>"${OUTPUT}"

echo "==> 结果已追加到 ${OUTPUT}"
