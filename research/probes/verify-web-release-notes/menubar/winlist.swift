import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionAll]
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { print("no info"); exit(1) }
print("total windows:", info.count)
var byLayer: [Int: [String]] = [:]
for w in info {
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let desc = "\(owner)(pid \(pid)) bounds=\(b["X"] ?? "?"),\(b["Y"] ?? "?"),\(b["Width"] ?? "?")x\(b["Height"] ?? "?") name=\(w[kCGWindowName as String] as? String ?? "-")"
    if layer >= 20 && layer <= 30 { byLayer[layer, default: []].append(desc) }
}
for l in byLayer.keys.sorted() { print("layer \(l): \(byLayer[l]!.count) windows"); for d in byLayer[l]!.prefix(40) { print("   ", d) } }
print("statusWindowLevel(CGWindowLevelForKey(.statusWindow)) =", CGWindowLevelForKey(.statusWindow))
print("mainMenuWindowLevel =", CGWindowLevelForKey(.mainMenuWindow))
