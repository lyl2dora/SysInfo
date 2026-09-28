#!/bin/zsh
# Diff public API surface (headers + arm64e-apple-macos.swiftinterface) of a
# framework between the CLT macOS 26.5 SDK and the Xcode macOS 27.0 SDK.
# Usage: diff_fw.sh Name [Name...]   -> writes diffs/<Name>.diff
X=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
C=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
O=${0:A:h}/diffs
mkdir -p $O
for n in "$@"; do
  a=$C/System/Library/Frameworks/$n.framework
  b=$X/System/Library/Frameworks/$n.framework
  out=$O/$n.diff
  : > $out
  # headers
  diff -ruN -x '*.swiftdoc' -x '*.tbd' -x '*.swiftmodule' -x '*.abi.json' -x '*.swiftsourceinfo' \
       -x '*ios-macabi*' -x 'x86_64*' -x '*.private.swiftinterface' -x '*.package.swiftinterface' \
       $a/Versions/Current/Headers $b/Versions/Current/Headers >> $out 2>/dev/null
  [ -d $a/Headers ] && [ ! -d $a/Versions ] && diff -ruN $a/Headers $b/Headers >> $out 2>/dev/null
  # swiftinterface (skip line 2-4 compiler/flags headers)
  sa=$(ls $a/Modules/$n.swiftmodule/arm64e-apple-macos.swiftinterface 2>/dev/null)
  sb=$(ls $b/Modules/$n.swiftmodule/arm64e-apple-macos.swiftinterface 2>/dev/null)
  if [ -n "$sa$sb" ]; then
    diff -uN <(sed '1,4d' ${sa:-/dev/null} 2>/dev/null) <(sed '1,4d' ${sb:-/dev/null} 2>/dev/null) \
      | sed "1s|.*|--- 26.5/$n.swiftinterface|;2s|.*|+++ 27.0/$n.swiftinterface|" >> $out
  fi
  plus=$(grep -c '^+[^+]' $out); minus=$(grep -c '^-[^-]' $out)
  printf "%-28s +%-6s -%-6s\n" $n $plus $minus
done
