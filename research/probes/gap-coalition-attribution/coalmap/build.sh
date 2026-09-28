#!/bin/sh
# builds coalmap.app (LSUIElement) so that `open -n` launches it in a fresh resource coalition
set -e
cd "$(dirname "$0")"
APP=CoalMap.app
mkdir -p $APP/Contents/MacOS
xcrun clang -O1 -c coalkit.c -o coalkit.o
xcrun swiftc -O -import-objc-header coalkit.h main.swift coalkit.o -o $APP/Contents/MacOS/CoalMap \
  -framework Metal -framework Vision -framework CoreGraphics -framework IOKit -framework CoreFoundation -L/usr/lib -lIOReport
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CoalMap</string>
<key>CFBundleIdentifier</key><string>local.probe.coalmap</string>
<key>CFBundleName</key><string>CoalMap</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign -s - -f $APP
