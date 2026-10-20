#!/bin/bash
# build.sh [outdir]：编译 mborder.app（ad-hoc 签名，bundle id local.probe.mborder）。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
app="$out/mborder.app"
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
xcrun swiftc -O "$here/mborder.swift" -o "$app/Contents/MacOS/mborder"
codesign -s - -f "$app" >/dev/null 2>&1
# 第二份拷贝换 bundle id，充当「其他 app」，用来看本 app 的 item 与别人的 item 怎么穿插
other="$out/mborder2.app"
rm -rf "$other"; cp -R "$app" "$other"
plutil -replace CFBundleIdentifier -string local.probe.mborder2 "$other/Contents/Info.plist"
codesign -s - -f "$other" >/dev/null 2>&1
echo "$app"
