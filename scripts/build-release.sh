#!/bin/bash
# 构建可分发的 Release 包（D74）：Release 配置构建 → 校验签名 → 打 zip →（有凭据时）公证、staple、Gatekeeper 评估 → 重新打 zip。
# CI（.github/workflows/release.yml）和本机 `make dist` 都走这个脚本。
#
# 环境变量：
#   OUT_DIR          输出目录（默认 build/dist）
#   DERIVED_DATA     DerivedData（默认 build/ReleaseDerivedData）
#   BUILD_NUMBER     build 号（默认 git rev-list --count HEAD）
#   GIT_COMMIT       git 短哈希（默认 git rev-parse --short HEAD）
#   SIGN_KEYCHAIN    签名证书所在的钥匙串（CI 用临时钥匙串；本机留空用默认钥匙串）
#   公证凭据（二选一，都不设时跳过公证，产物只签名）：
#     NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   App Store Connect API key（CI 用）
#     NOTARY_PROFILE                                       notarytool store-credentials 存的钥匙串配置名（本机用）
#   REQUIRE_NOTARIZATION=1   没有公证凭据时报错退出（CI 发布时设置）
#
# 产物：$OUT_DIR/SysInfo-<版本>.zip 与同名 .sha256。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repo_root}"

OUT_DIR="${OUT_DIR:-build/dist}"
DERIVED_DATA="${DERIVED_DATA:-build/ReleaseDerivedData}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse --short HEAD)$(git diff --quiet HEAD 2>/dev/null || echo -dirty)}"
TEAM_ID="D8MFB2YNN3"
BUNDLE_ID="zone.lyl.sysinfo"

version="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Shared.xcconfig)"
[ -n "${version}" ] || { echo "读不到 MARKETING_VERSION" >&2; exit 1; }
app="${DERIVED_DATA}/Build/Products/Release/SysInfo.app"
zip="${OUT_DIR}/SysInfo-${version}.zip"

notarize=0
if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    notary_auth=(--key "${NOTARY_KEY_PATH}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID}")
    notarize=1
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    notary_auth=(--keychain-profile "${NOTARY_PROFILE}")
    notarize=1
elif [ "${REQUIRE_NOTARIZATION:-0}" = "1" ]; then
    echo "REQUIRE_NOTARIZATION=1，但没有公证凭据" >&2
    exit 1
fi

sign_flags="--timestamp"
[ -n "${SIGN_KEYCHAIN:-}" ] && sign_flags+=" --keychain ${SIGN_KEYCHAIN}"

echo "==> 构建 SysInfo ${version}（build ${BUILD_NUMBER}，${GIT_COMMIT}）"
rm -rf "${app}"
xcodebuild -project SysInfo.xcodeproj -scheme SysInfo -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "${DERIVED_DATA}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" SYSINFO_GIT_COMMIT="${GIT_COMMIT}" \
    OTHER_CODE_SIGN_FLAGS="${sign_flags}" build -quiet
[ -d "${app}" ] || { echo "构建产物不存在：${app}" >&2; exit 1; }

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "${app}"
details="$(codesign -dv --verbose=4 "${app}" 2>&1)"
grep -q "^TeamIdentifier=${TEAM_ID}$" <<<"${details}" || { echo "Team ID 不是 ${TEAM_ID}" >&2; exit 1; }
grep -q "^Identifier=${BUNDLE_ID}$" <<<"${details}" || { echo "Bundle ID 不是 ${BUNDLE_ID}" >&2; exit 1; }
grep -q "flags=.*runtime" <<<"${details}" || { echo "没有开启 Hardened Runtime" >&2; exit 1; }
grep -q "^Timestamp=" <<<"${details}" || { echo "签名没有安全时间戳" >&2; exit 1; }
if codesign -d --entitlements - --xml "${app}" 2>/dev/null | grep -q "get-task-allow"; then
    echo "签名带 get-task-allow，公证会拒绝（D20）" >&2
    exit 1
fi
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")"
[ "${plist_version}" = "${version}" ] || { echo "Info.plist 版本 ${plist_version} 与 ${version} 不一致" >&2; exit 1; }

mkdir -p "${OUT_DIR}"
rm -f "${zip}" "${zip}.sha256"
ditto -c -k --keepParent "${app}" "${zip}"

if [ "${notarize}" = "1" ]; then
    echo "==> 公证（notarytool，等待结果）"
    xcrun notarytool submit "${zip}" "${notary_auth[@]}" --wait --timeout 30m
    xcrun stapler staple "${app}"
    xcrun stapler validate "${app}"
    spctl --assess --type execute --verbose=2 "${app}"
    # staple 之后重新打包，下载到的 app 自带公证票据，离线也能通过 Gatekeeper。
    rm -f "${zip}"
    ditto -c -k --keepParent "${app}" "${zip}"
else
    echo "==> 没有公证凭据，跳过公证（产物只签名，经浏览器下载后会被 Gatekeeper 拦下）"
fi

(cd "${OUT_DIR}" && shasum -a 256 "$(basename "${zip}")" >"$(basename "${zip}").sha256")
echo "==> 产物：${zip}"
cat "${zip}.sha256"
