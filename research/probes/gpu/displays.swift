// Probe: displays (count, mode, refresh rate) via CoreGraphics + NSScreen
// build: xcrun swiftc -O -o displays displays.swift -framework AppKit -framework CoreGraphics
import AppKit
import CoreGraphics

var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
var online = [CGDirectDisplayID](repeating: 0, count: 16); var on: UInt32 = 0
CGGetOnlineDisplayList(16, &online, &on)
print("active displays: \(n), online displays: \(on)")
for id in ids.prefix(Int(n)) {
    let m = CGDisplayCopyDisplayMode(id)
    print(String(format: "  id=%u builtin=%d main=%d asleep=%d mirrored=%d %zux%zu px (%zux%zu pt) refresh=%.2f Hz vendor=%u model=%u",
                 id, CGDisplayIsBuiltin(id), CGDisplayIsMain(id), CGDisplayIsAsleep(id), CGDisplayIsInMirrorSet(id),
                 m?.pixelWidth ?? 0, m?.pixelHeight ?? 0, m?.width ?? 0, m?.height ?? 0, m?.refreshRate ?? -1, CGDisplayVendorNumber(id), CGDisplayModelNumber(id)))
}
for s in NSScreen.screens {
    print("  NSScreen \(s.localizedName): maximumFramesPerSecond=\(s.maximumFramesPerSecond) minimumRefreshInterval=\(s.minimumRefreshInterval) maximumRefreshInterval=\(s.maximumRefreshInterval) backingScale=\(s.backingScaleFactor) EDR max=\(s.maximumPotentialExtendedDynamicRangeColorComponentValue)")
}
