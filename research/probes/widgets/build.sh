#!/bin/zsh
# 用法：build.sh dev|rel|devmode [outdir]
#   dev     标识 zone.lyl.sysinfo.dev.probe（Debug 形态）
#   rel     标识 zone.lyl.sysinfo.probe（Release 形态）
#   devmode 同 dev，但扩展带 get-task-allow（probe E）
#   reldevmode 同 rel，但扩展带 get-task-allow（probe E，不打断 dev 上的长时 B2）
set -euo pipefail
here=${0:A:h}
variant=${1:?dev|rel|devmode|reldevmode}
out=${2:-$here/out}
case $variant in
  dev|devmode) id=zone.lyl.sysinfo.dev.probe; name="SysInfo Probe Dev" ;;
  rel|reldevmode) id=zone.lyl.sysinfo.probe; name="SysInfo Probe Rel" ;;
  *) echo "unknown variant $variant" >&2; exit 2 ;;
esac
ent=Ext/Ext.entitlements
[[ $variant == *devmode ]] && ent=Ext/ExtDevMode.entitlements
# devmode 变体覆盖同标识的普通版（同一 bundle ID 只能留一份，见 A 的发现）
slot=$variant; [[ $variant == devmode ]] && slot=dev; [[ $variant == reldevmode ]] && slot=rel
mkdir -p $out
# xcodegen 生成的工程放在 out/，不进库
cp -R $here/project.yml $here/Shared $here/Host $here/Ext $out/
(cd $out && xcodegen generate --quiet)
xcodebuild -project $out/WidgetProbe.xcodeproj -scheme ProbeHost -configuration Release \
  -derivedDataPath $out/dd-$variant \
  PROBE_ID=$id PROBE_GROUP=D8MFB2YNN3.$id PROBE_NAME="$name" PROBE_EXT_ENTITLEMENTS=$ent \
  -quiet build
app=$out/dd-$variant/Build/Products/Release/SysInfoProbe.app
rm -rf $out/$slot && mkdir -p $out/$slot && cp -R $app $out/$slot/
# 同一 bundle ID 留两份时 pkd 只认其中一份（9-28 Stats 的教训），删掉 DerivedData 里的副本并注销
lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$lsreg -u $app 2>/dev/null || true
rm -rf $out/dd-$variant/Build/Products
$lsreg -f $out/$slot/SysInfoProbe.app
echo $out/$slot/SysInfoProbe.app
