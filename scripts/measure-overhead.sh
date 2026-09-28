#!/bin/bash
# 自身开销测量（M0 设计 §9，K26、D19、D18）。
#
# 用 Release 配置构建 app，按两档各测一次，结果追加到 docs/perf/m0.md：
#   1. 出厂默认配置：1 个 CPU item，面板关闭；
#   2. 面板打开：带 --open-panel 启动。
# 每档先预热 WARMUP 秒，再测 DURATION 秒。app 的 CPU 占用用 `ps -o time=` 的差值算（按单核的比例）；
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
#          OUTPUT（默认 docs/perf/m0.md）。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repo_root}"

WARMUP="${WARMUP:-30}"
DURATION="${DURATION:-120}"
BASELINE="${BASELINE:-1}"
OUTPUT="${OUTPUT:-docs/perf/m0.md}"

derived_data="build/MeasureDerivedData"
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

build_number="$(git rev-list --count HEAD)"
git_commit="$(git rev-parse --short HEAD)$(git diff --quiet HEAD 2>/dev/null || echo -dirty)"

echo "==> 构建 Release 配置（Bundle ID 改为 zone.lyl.sysinfo.dev）"
xcodebuild -project SysInfo.xcodeproj -scheme SysInfo -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "${derived_data}" \
    CURRENT_PROJECT_VERSION="${build_number}" SYSINFO_GIT_COMMIT="${git_commit}" \
    PRODUCT_BUNDLE_IDENTIFIER=zone.lyl.sysinfo.dev INFOPLIST_KEY_CFBundleDisplayName="SysInfo Dev" \
    build -quiet
[ -x "${exe}" ] || { echo "构建产物不存在：${exe}" >&2; exit 1; }

# ---------------------------------------------------------------- 测量

app_pid=""
cleanup() {
    if [ -n "${app_pid}" ] && kill -0 "${app_pid}" 2>/dev/null; then
        kill -TERM "${app_pid}" 2>/dev/null || true
        wait "${app_pid}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

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
        "${exe}" "$@" >/dev/null 2>&1 &
        app_pid=$!
        echo "==> [${label}] 启动 pid ${app_pid}，参数：$*；预热 ${WARMUP}s" >&2
        sleep "${WARMUP}"
        kill -0 "${app_pid}" 2>/dev/null || { echo "app 在预热期间退出了" >&2; exit 1; }
    else
        echo "==> [baseline] 不运行 SysInfo" >&2
    fi

    local t0 a0="" m0 w0 t1 a1="" m1 w1
    t0="$(now)"
    [ -n "${app_pid}" ] && a0="$(cpu_seconds "${app_pid}")"
    m0="$(cpu_seconds "${mba_pid}")"
    w0="$(cpu_seconds "${ws_pid}")"
    echo "    测量 ${DURATION}s …" >&2
    sleep "${DURATION}"
    t1="$(now)"
    [ -n "${app_pid}" ] && a1="$(cpu_seconds "${app_pid}")"
    m1="$(cpu_seconds "${mba_pid}")"
    w1="$(cpu_seconds "${ws_pid}")"

    local elapsed app_pct="—" footprint="—"
    elapsed="$(perl -e 'printf "%.3f", $ARGV[1] - $ARGV[0]' "${t0}" "${t1}")"
    if [ -n "${app_pid}" ]; then
        app_pct="$(percent "${a0}" "${a1}" "${elapsed}")"
        footprint="$(/usr/bin/footprint -p "${app_pid}" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p' | head -1)"
        [ -n "${footprint}" ] || footprint="?"
        # 面板档：测量期间若有人点了别处或按了 Esc，面板会关闭，这一档作废。
        if [ "${label}" = "panel" ]; then
            if /usr/bin/log show --last "$((WARMUP + DURATION + 30))s" --info --style compact \
                --predicate "processID == ${app_pid} AND category == \"panel\"" 2>/dev/null | grep -q "面板已隐藏"; then
                note="面板在测量期间被关闭，本档作废"
            fi
        fi
        kill -TERM "${app_pid}" 2>/dev/null || true
        wait "${app_pid}" 2>/dev/null || true
        app_pid=""
        sleep 3
    fi
    local mba_pct ws_pct
    mba_pct="$(percent "${m0}" "${m1}" "${elapsed}")"
    ws_pct="$(percent "${w0}" "${w1}" "${elapsed}")"
    echo "    app ${app_pct}%  MenuBarAgent ${mba_pct}%  WindowServer ${ws_pct}%  footprint ${footprint} ${note}" >&2
    results+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "${label}" "${app_pct}" "${mba_pct}" "${ws_pct}" "${footprint}" "${note}")")
}

echo "测量期间请不要操作鼠标和键盘（面板档会因点击别处或按 Esc 而关闭）。" >&2
if [ "${BASELINE}" != "0" ]; then
    measure baseline
fi
measure default --factory-defaults
measure panel --factory-defaults --open-panel

# ---------------------------------------------------------------- 写结果

model="$(sysctl -n hw.model)"
chip="$(sysctl -n machdep.cpu.brand_string)"
ncpu="$(sysctl -n hw.logicalcpu)"
os="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
date_str="$(date '+%Y-%m-%d %H:%M')"

mkdir -p "$(dirname "${OUTPUT}")"
if [ ! -f "${OUTPUT}" ]; then
    cat >"${OUTPUT}" <<'EOF'
# M0 自身开销测量

> 由 `make measure`（`scripts/measure-overhead.sh`）追加，口径见 M0 设计 §9、K26：
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
    echo "| 档位 | app CPU（单核 %） | MenuBarAgent（%） | WindowServer（%） | app footprint | 备注 |"
    echo "|---|---|---|---|---|---|"
    for row in "${results[@]}"; do
        IFS=$'\t' read -r label app_pct mba_pct ws_pct footprint note <<<"${row}"
        case "${label}" in
            baseline) name="基线（不运行 SysInfo）" ;;
            default) name="出厂默认（1 个 CPU item，面板关闭）" ;;
            panel) name="面板打开（--open-panel）" ;;
            *) name="${label}" ;;
        esac
        echo "| ${name} | ${app_pct} | ${mba_pct} | ${ws_pct} | ${footprint} | ${note:-} |"
    done
} >>"${OUTPUT}"

echo "==> 结果已追加到 ${OUTPUT}"
