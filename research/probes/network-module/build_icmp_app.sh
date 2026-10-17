#!/bin/zsh
# 构建并用 Developer ID 签名 K47 探针 app（独立 bundle id，不碰 SysInfo 的授权记录）。
set -e
cd "$(dirname "$0")"
APP=build/ICMPProbe.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
xcrun clang -O2 -arch arm64 -o $APP/Contents/MacOS/ICMPProbe icmp_app.c
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>zone.lyl.sysinfo.probe.icmp</string>
<key>CFBundleName</key><string>ICMPProbe</string>
<key>CFBundleDisplayName</key><string>SysInfo ICMP Probe</string>
<key>CFBundleExecutable</key><string>ICMPProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PL
codesign --force --options runtime --timestamp=none -s "Developer ID Application" $APP
codesign -dv $APP 2>&1 | grep -E "Identifier|Authority=Developer|flags"
