// Read-only: enumerate on-screen windows at menu-bar / status levels via CGWindowListCopyWindowInfo.
import CoreGraphics
import AppKit
let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
print("kCGStatusWindowLevel =", statusLevel, " kCGMainMenuWindowLevel =", mainMenuLevel)
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { print("no list"); exit(1) }
print("total on-screen windows:", list.count)
var byLevel: [Int: Int] = [:]
for w in list { byLevel[(w[kCGWindowLayer as String] as? Int) ?? -999, default: 0] += 1 }
print("windows per layer:", byLevel.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
print("\nWindows with layer in [20, 30] (menu bar / status items):")
for w in list {
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -999
    guard (20...30).contains(layer) else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let name = w[kCGWindowName as String] as? String ?? "(no name / needs Screen Recording)"
    print(String(format: "layer=%d pid=%d owner=%@ bounds=%@,%@ %@x%@ name=%@", layer, pid, owner, "\(b["X"] ?? "")", "\(b["Y"] ?? "")", "\(b["Width"] ?? "")", "\(b["Height"] ?? "")", name))
}
