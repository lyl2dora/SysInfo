import AppKit
import ObjectiveC
_ = NSApplication.shared
var names: [String] = []
for img in ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI"] {
  var count: UInt32 = 0
  guard let cn = objc_copyClassNamesForImage(img, &count) else { print("no image", img); continue }
  for i in 0..<Int(count) {
    let n = String(cString: cn[i])
    if (n.localizedCaseInsensitiveContains("StatusItem") || n.localizedCaseInsensitiveContains("StatusBar") || n.localizedCaseInsensitiveContains("MenuBarExtra") || n.localizedCaseInsensitiveContains("MenuBarNav") || n.localizedCaseInsensitiveContains("Overflow")) { names.append(n + "  [" + (img as NSString).lastPathComponent + "]") }
  }
}
names.sort()
print("classes:"); names.forEach { print("  " + $0) }
func dump(_ name: String) {
  guard let c = NSClassFromString(name) else { print("\n## \(name): absent"); return }
  print("\n## \(name) : \(NSStringFromClass(class_getSuperclass(c) ?? NSObject.self))")
  var mc: UInt32 = 0
  if let ms = class_copyMethodList(c, &mc) { var s: [String] = []; for i in 0..<Int(mc) { s.append(NSStringFromSelector(method_getName(ms[i]))) }; print("  methods(\(mc)): " + s.sorted().joined(separator: " ")) }
  var pc: UInt32 = 0
  if let ps = class_copyPropertyList(c, &pc) { var s: [String] = []; for i in 0..<Int(pc) { s.append(String(cString: property_getName(ps[i]))) }; print("  props: " + s.sorted().joined(separator: " ")) }
  var ic: UInt32 = 0
  if let iv = class_copyIvarList(c, &ic) { var s: [String] = []; for i in 0..<Int(ic) { s.append(String(cString: ivar_getName(iv[i])!)) }; print("  ivars: " + s.joined(separator: " ")) }
}
for n in CommandLine.arguments.dropFirst() { dump(n) }
