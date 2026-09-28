// mbprobe: macOS 27 status-item runtime probe (read-only; only touches its own status items/windows)
// Modes: image (A) | view (B, NSStatusItem.view) | subview (B', Stats-style subview of button) | swiftui (C, MenuBarExtra)
//        popup (NSPopover / NSPanel+NSGlassEffectView, expandedInterfaceDelegate) | info
// Flags: --n N --secs S --churn (D: width changes each tick) --patch (Stats tiling patch) --color (colored swatches for screenshots)
//        --shots DIR (screencapture menu bar strip at ticks 4/5, needs Screen Recording of responsible process)
//        --itemw W (fixed width, overflow test) --report K (per-item report every K s) --swizzle (log scene callbacks)
import AppKit
import SwiftUI
import ObjectiveC
import Darwin
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func opt(_ k: String) -> String? { if let i = args.firstIndex(of: k), i + 1 < args.count { return args[i + 1] }; return nil }
func flag(_ k: String) -> Bool { args.contains(k) }
let MODE = opt("--mode") ?? "image"
let N = Int(opt("--n") ?? "1") ?? 1
let SECS = Double(opt("--secs") ?? "120") ?? 120
let CHURN = flag("--churn")
let PATCH = flag("--patch")
let COLOR = flag("--color")
let SHOTS = opt("--shots")
let ITEMW = Double(opt("--itemw") ?? "0") ?? 0
let REPORT = Double(opt("--report") ?? "0") ?? 0
let SWZ = flag("--swizzle")
let POPUP = opt("--popup") ?? "popover"
let DELEGATE = flag("--delegate")
let REALCLICK = flag("--realclick")
let T0 = CACurrentMediaTime()
func log(_ s: String) { print(String(format: "[%8.3f] ", CACurrentMediaTime() - T0) + s) }

// MARK: - private-call helpers (own process only)
func desc(_ o: Any?) -> String {
    guard let o else { return "nil" }
    let s = String(describing: o).replacingOccurrences(of: "\n", with: " ")
    return s.count > 600 ? String(s.prefix(600)) + "…" : s
}
func call(_ obj: AnyObject?, _ name: String) -> String {
    guard let obj else { return "nil-obj" }
    let sel = NSSelectorFromString(name)
    guard let cls = object_getClass(obj), let m = class_getInstanceMethod(cls, sel) else { return "n/a" }
    let imp = method_getImplementation(m)
    let rtp = method_copyReturnType(m); let rt = String(cString: rtp); free(rtp)
    if method_getNumberOfArguments(m) != 2 { return "args!=0" }
    switch rt.first {
    case "B": typealias F = @convention(c) (AnyObject, Selector) -> Bool; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "c": typealias F = @convention(c) (AnyObject, Selector) -> Int8; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "d": typealias F = @convention(c) (AnyObject, Selector) -> Double; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "f": typealias F = @convention(c) (AnyObject, Selector) -> Float; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "q", "l": typealias F = @convention(c) (AnyObject, Selector) -> Int; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "Q", "L": typealias F = @convention(c) (AnyObject, Selector) -> UInt; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "i": typealias F = @convention(c) (AnyObject, Selector) -> Int32; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "I": typealias F = @convention(c) (AnyObject, Selector) -> UInt32; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))"
    case "@": typealias F = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?; return desc(unsafeBitCast(imp, to: F.self)(obj, sel)?.takeUnretainedValue())
    case "{":
        if rt.hasPrefix("{CGRect") { typealias F = @convention(c) (AnyObject, Selector) -> CGRect; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))" }
        if rt.hasPrefix("{CGSize") { typealias F = @convention(c) (AnyObject, Selector) -> CGSize; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))" }
        if rt.hasPrefix("{CGPoint") { typealias F = @convention(c) (AnyObject, Selector) -> CGPoint; return "\(unsafeBitCast(imp, to: F.self)(obj, sel))" }
        return "struct:\(rt)"
    default: return "rt:\(rt)"
    }
}
func ivar(_ obj: AnyObject, _ name: String) -> AnyObject? {
    guard let cls = object_getClass(obj), let iv = class_getInstanceVariable(cls, name) else { return nil }
    let enc = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? ""
    guard enc.hasPrefix("@") else { return nil }
    return object_getIvar(obj, iv) as AnyObject?
}
func encoding(_ cls: String, _ sel: String) -> String {
    guard let c = NSClassFromString(cls), let m = class_getInstanceMethod(c, NSSelectorFromString(sel)) else { return "absent" }
    return method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
}

// MARK: - Stats' tiling patch (Stats/helpers.swift:398-405)
func applyTilingPatch() {
    let selector = NSSelectorFromString("_needsTilingConstraintUpdate")
    guard let cls = NSClassFromString("NSStatusBarWindow") else { log("PATCH: NSStatusBarWindow absent"); return }
    guard let method = class_getInstanceMethod(cls, selector) else { log("PATCH: _needsTilingConstraintUpdate absent"); return }
    let block: @convention(block) (AnyObject) -> Bool = { _ in false }
    let added = class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    log("PATCH: class_addMethod(NSStatusBarWindow, _needsTilingConstraintUpdate) -> \(added)")
}

// MARK: - swizzle loggers for scene traffic (own process)
var swzCounts: [String: Int] = [:]
func swz1(_ clsName: String, _ selName: String, verbose: Bool = true) {
    guard let cls = NSClassFromString(clsName), let m = class_getInstanceMethod(cls, NSSelectorFromString(selName)) else { log("swz miss \(clsName).\(selName)"); return }
    let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? ""
    let sel = NSSelectorFromString(selName)
    let orig = method_getImplementation(m)
    let key = "\(clsName).\(selName)"
    if enc.hasPrefix("v") && method_getNumberOfArguments(m) == 3 && enc.contains("@16") {
        typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let o = unsafeBitCast(orig, to: F.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { s, a in
            swzCounts[key, default: 0] += 1
            if verbose { log("SWZ \(key) a=\(desc(a))") }
            o(s, sel, a)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else if enc.hasPrefix("v") && method_getNumberOfArguments(m) == 4 && enc.contains("@16@24") {
        typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let o = unsafeBitCast(orig, to: F.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { s, a, b in
            swzCounts[key, default: 0] += 1
            if verbose { log("SWZ \(key) a=\(desc(a)) b=\(desc(b))") }
            o(s, sel, a, b)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else if enc.hasPrefix("v") && method_getNumberOfArguments(m) == 3 && (enc.contains("B16") || enc.contains("c16")) {
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        let o = unsafeBitCast(orig, to: F.self)
        let block: @convention(block) (AnyObject, Bool) -> Void = { s, a in
            swzCounts[key, default: 0] += 1
            if verbose { log("SWZ \(key) a=\(a)") }
            o(s, sel, a)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else if enc.hasPrefix("v") && method_getNumberOfArguments(m) == 4 && (enc.contains("B16B20") || enc.contains("c16c20")) {
        typealias F = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        let o = unsafeBitCast(orig, to: F.self)
        let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { s, a, b in
            swzCounts[key, default: 0] += 1
            if verbose { log("SWZ \(key) a=\(a) b=\(b)"); if flag("--bt") { Thread.callStackSymbols.prefix(14).forEach { print("      bt: " + $0) } } }
            o(s, sel, a, b)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else if enc.hasPrefix("v") && method_getNumberOfArguments(m) == 2 {
        typealias F = @convention(c) (AnyObject, Selector) -> Void
        let o = unsafeBitCast(orig, to: F.self)
        let block: @convention(block) (AnyObject) -> Void = { s in
            swzCounts[key, default: 0] += 1
            if verbose { log("SWZ \(key)") }
            o(s, sel)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else { log("swz skip \(key) enc=\(enc)") ; return }
    log("swz ok \(key) enc=\(enc)")
}
func installSwizzles() {
    swz1("NSSceneStatusItem", "scene:didUpdateSettings:")
    swz1("NSSceneStatusItem", "_updateForStatusItemSceneDiff:")
    swz1("NSSceneStatusItem", "_updateForVariantSceneDiff:")
    swz1("NSSceneStatusItem", "scene:handleActions:")
    swz1("NSSceneStatusItem", "_setVisible:temporary:")
    swz1("NSSceneStatusItem", "_beginExpandedInterfaceSession:")
    swz1("NSSceneStatusItem", "_endExpandedInterfaceSession:animate:")
    swz1("NSSceneStatusItem", "_requestExpandedInterfaceSession")
    swz1("NSStatusItem", "_setHidden:")
    swz1("NSStatusItem", "_setHideFromBar:")
    swz1("NSStatusItem", "_windowStatusItemViewGeometryDidChange:", verbose: false)
    swz1("NSStatusItemScene", "updateSettings:", verbose: false)
    swz1("NSStatusItemScene", "updateStatusItemOnBackgroundThread:", verbose: false)
    swz1("NSStatusItemVariantScene", "updateSettings:", verbose: false)
    swz1("NSStatusItemVariantScene", "updateStatusItemOnBackgroundThread:", verbose: false)
}

// MARK: - drawing
let HUESTEP: CGFloat = min(0.09, 0.9 / CGFloat(max(N, 1)))
func hue(_ i: Int) -> CGFloat { (0.30 + CGFloat(i) * HUESTEP).truncatingRemainder(dividingBy: 1) }
var series: [[Double]] = []
func nextValue(_ i: Int, _ tick: Int) -> Double { 50 + 45 * sin(Double(tick) * 0.7 + Double(i)) }
func widthFor(_ i: Int, _ tick: Int) -> CGFloat {
    if ITEMW > 0 { return CGFloat(ITEMW) }
    var w: CGFloat = 62 + (COLOR ? 18 : 0)
    if CHURN { w += CGFloat(tick % 3) * 14 }
    return w
}
func drawWidget(_ rect: NSRect, idx: Int, tick: Int, fg: NSColor) {
    var x: CGFloat = 2
    if COLOR {
        NSColor(colorSpace: .sRGB, hue: hue(idx), saturation: 1, brightness: 1, alpha: 1).setFill()
        NSRect(x: x, y: 3, width: 6, height: rect.height - 6).fill()
        if tick % 2 == 0 { NSRect(x: x + 8, y: 3, width: 6, height: rect.height - 6).fill() }
        x += 18
    }
    let vals = series[idx]
    let chartW = rect.width - x - 30
    let path = NSBezierPath(); path.lineWidth = 1.2
    for (k, v) in vals.enumerated() {
        let px = x + chartW * CGFloat(k) / CGFloat(max(vals.count - 1, 1))
        let py = 3 + (rect.height - 6) * CGFloat(v / 100)
        if k == 0 { path.move(to: NSPoint(x: px, y: py)) } else { path.line(to: NSPoint(x: px, y: py)) }
    }
    fg.setStroke(); path.stroke()
    let s = String(format: "%2.0f%%", vals.last ?? 0)
    (s as NSString).draw(at: NSPoint(x: rect.width - 28, y: 4), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: fg])
}
var imagesMade = 0
func makeImage(_ idx: Int, _ tick: Int) -> NSImage {
    let w = widthFor(idx, tick); let h = NSStatusBar.system.thickness
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
        drawWidget(r, idx: idx, tick: tick, fg: COLOR ? NSColor.labelColor : .black); return true }
    img.isTemplate = !COLOR
    imagesMade += 1
    return img
}
final class WidgetView: NSView {
    var idx = 0; var tick = 0; var draws = 0; var drawsSinceReport = 0
    override func draw(_ dirtyRect: NSRect) { draws += 1; drawsSinceReport += 1; drawWidget(bounds, idx: idx, tick: tick, fg: .labelColor) }
    override func viewDidHide() { log("item\(idx) viewDidHide") }
    override func viewDidUnhide() { log("item\(idx) viewDidUnhide") }
    override func viewDidMoveToWindow() { log("item\(idx) viewDidMoveToWindow window=\(window.map { "\(type(of: $0)) #\(String($0.windowNumber, radix: 16))" } ?? "nil")") }
    override func viewDidChangeEffectiveAppearance() { log("item\(idx) appearance -> \(effectiveAppearance.name.rawValue)") }
}

// MARK: - rusage / memory
func cpuSeconds() -> Double {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}
func footprintMB() -> Double {
    var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
}

// MARK: - CG window list for own pid
func ownCGWindows() -> [String] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let me = Int(getpid())
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == me }.map { w in
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return "cgwin #\(w[kCGWindowNumber as String] ?? 0) layer=\(w[kCGWindowLayer as String] ?? 0) bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) onscreen=\(w[kCGWindowIsOnscreen as String] ?? "nil") name=\(w[kCGWindowName as String] ?? "")"
    }
}
func menubarCGWindows() -> [String] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { let l = $0[kCGWindowLayer as String] as? Int ?? 0; return l == 24 || l == 25 || ($0[kCGWindowOwnerName as String] as? String) == "MenuBarAgent" || ($0[kCGWindowOwnerName as String] as? String) == "控制中心" || ($0[kCGWindowOwnerName as String] as? String) == "Control Center" }.map { w in
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return "  mbwin #\(w[kCGWindowNumber as String] ?? 0) pid=\(w[kCGWindowOwnerPID as String] ?? 0) owner=\(w[kCGWindowOwnerName as String] ?? "") layer=\(w[kCGWindowLayer as String] ?? 0) bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) onscreen=\(w[kCGWindowIsOnscreen as String] ?? "nil") name=\(w[kCGWindowName as String] ?? "")"
    }
}

// MARK: - screenshot + swatch analysis
func screencapture(_ path: String, rect: CGRect) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
    do { try p.run(); p.waitUntilExit() } catch { log("screencapture failed \(error)"); return false }
    return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
}
func analyzeShot(_ path: String, items: Int) -> [Int: [ClosedRange<Int>]] {
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else { log("cannot load \(path)"); return [:] }
    var cols: [Int: [Int]] = [:] // item -> xs
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    for x in 0..<rep.pixelsWide {
        var counts = [Int](repeating: 0, count: items)
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.saturationComponent > 0.55 && c.brightnessComponent > 0.45 {
                let h = c.hueComponent
                for i in 0..<items { var d = abs(h - hue(i)); d = min(d, 1 - d); if d < HUESTEP * 0.4 { counts[i] += 1 } }
            }
        }
        for i in 0..<items where counts[i] >= Int(13 * scale) { cols[i, default: []].append(Int(CGFloat(x) / scale)) }
    }
    var res: [Int: [ClosedRange<Int>]] = [:]
    for (i, xs) in cols {
        var runs: [ClosedRange<Int>] = []; var s = xs[0]; var p = xs[0]
        for x in xs.dropFirst() { if x == p + 1 { p = x } else { runs.append(s...p); s = x; p = x } }
        runs.append(s...p); runs = runs.filter { $0.count >= 4 && $0.count <= 9 }; if !runs.isEmpty { res[i] = runs }
    }
    return res
}

// MARK: - layer/view dumps
func dumpViews(_ v: NSView, _ d: Int = 0, _ out: inout [String], maxLines: Int = 80) {
    if out.count >= maxLines { return }
    var extra = ""
    if let ve = v as? NSVisualEffectView { extra = " material=\(ve.material.rawValue) blending=\(ve.blendingMode.rawValue) state=\(ve.state.rawValue)" }
    if let g = v as? NSGlassEffectView { extra = " glass style=\(g.style.rawValue) r=\(g.cornerRadius)" }
    out.append(String(repeating: "  ", count: d) + "\(type(of: v)) \(Int(v.frame.width))x\(Int(v.frame.height))" + extra)
    for s in v.subviews { dumpViews(s, d + 1, &out, maxLines: maxLines) }
}
func dumpLayers(_ l: CALayer, _ d: Int = 0, _ out: inout [String], maxLines: Int = 80) {
    if out.count >= maxLines { return }
    var extra = ""
    if let f = l.filters, !f.isEmpty { extra += " filters=\(f.count)" }
    if let n = l.name { extra += " '\(n)'" }
    out.append(String(repeating: " ", count: d) + String(describing: type(of: l)) + extra)
    for s in l.sublayers ?? [] { dumpLayers(s, d + 1, &out, maxLines: maxLines) }
}
func glassMarkers(_ root: NSView) -> String {
    var views: [String] = []; var layers: [String] = []
    dumpViews(root, 0, &views, maxLines: 10000)
    if let l = root.layer { dumpLayers(l, 0, &layers, maxLines: 10000) }
    let all = (views + layers).joined(separator: "\n")
    let keys = ["NSGlassEffectView", "Glass", "SDFLayer", "CASDFLayer", "CABackdropLayer", "PortalLayer", "NSVisualEffectView", "CAChameleonLayer", "kCUIVariant"]
    return keys.map { k in "\(k)=\(all.components(separatedBy: k).count - 1)" }.joined(separator: " ")
}

// MARK: - item report
var items: [NSStatusItem] = []
var views: [WidgetView] = []
var lastReport: [Int: String] = [:]
func itemReport(_ i: Int, _ it: NSStatusItem, full: Bool) -> String {
    let b = it.button
    let w = b?.window ?? it.view?.window
    var s = "item\(i) cls=\(type(of: it)) isVisible=\(it.isVisible) length=\(it.length)"
    if let w {
        s += " win=\(type(of: w)) #0x\(String(w.windowNumber, radix: 16)) frame=\(w.frame) occl=\(w.occlusionState.rawValue)(visible=\(w.occlusionState.contains(.visible))) screen=\(w.screen.map { "\($0.frame) id=\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "?") name='\($0.localizedName)'" } ?? "nil") winVisible=\(w.isVisible) onActiveSpace=\(w.isOnActiveSpace)"
    } else { s += " win=nil" }
    s += " _isHidden=\(call(it, "_isHidden")) _hideFromBar=\(call(it, "_hideFromBar")) approxFrame=\(call(it, "_approximatedWindowFrame")) screen()=\(call(it, "screen"))"
    if let b { s += " btn.visibleRect=\(b.visibleRect) axFrame=\(b.accessibilityFrame())" }
    if full {
        s += " _menuBarHeight=\(call(it, "_menuBarHeight")) _displayIdentifier=\(call(it, "_displayIdentifier")) hostWindowID=\(call(it, "hostWindowID")) _priority=\(call(it, "_priority")) _systemInsertOrder=\(call(it, "_systemInsertOrder")) _useScenes=\(call(NSStatusBar.system, "_useScenes")) autosave=\(it.autosaveName) visKey=\(call(it, "_visibleDefaultsKey")) visCCKey=\(call(it, "_visibleCCDefaultsKey")) prefPosKey=\(call(it, "_preferredPositionDefaultsKey"))"
        if let w { s += " statusBarWindow.menuBarHeight=\(call(w, "menuBarHeight")) respondsTiling=\(w.responds(to: NSSelectorFromString("_needsTilingConstraintUpdate"))) tilingNow=\(call(w, "_needsTilingConstraintUpdate"))" }
    }
    if i < views.count { s += " draws=\(views[i].draws) (+\(views[i].drawsSinceReport))"; views[i].drawsSinceReport = 0 }
    return s
}
func reportAll(_ tag: String, full: Bool = false) {
    log("---- report \(tag) ----")
    for (i, it) in items.enumerated() {
        let r = itemReport(i, it, full: full)
        log(r)
        lastReport[i] = r
    }
    if full { ownCGWindows().forEach { log($0) } }
}

// MARK: - observers
var kvos: [NSKeyValueObservation] = []
var observedWindows = Set<ObjectIdentifier>()
func observe(_ i: Int, _ it: NSStatusItem) {
    kvos.append(it.observe(\.isVisible, options: [.old, .new]) { _, ch in log("KVO item\(i).isVisible \(String(describing: ch.oldValue)) -> \(String(describing: ch.newValue))") })
    kvos.append(it.observe(\.length, options: [.old, .new]) { _, ch in if !CHURN { log("KVO item\(i).length \(String(describing: ch.oldValue)) -> \(String(describing: ch.newValue))") } })
    if let b = it.button ?? (it.view as? NSButton) {
        kvos.append(b.observe(\.window, options: [.new]) { _, _ in log("KVO item\(i).button.window changed") })
        b.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: b, queue: .main) { _ in if !CHURN { log("NOTE item\(i) button frameDidChange \(b.frame)") } }
    }
    if let w = it.button?.window ?? it.view?.window, !observedWindows.contains(ObjectIdentifier(w)) {
        observedWindows.insert(ObjectIdentifier(w))
        let names: [NSNotification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification, NSWindow.didExposeNotification, NSWindow.didChangeScreenProfileNotification]
        for n in names {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { _ in
                if CHURN && (n == NSWindow.didResizeNotification || n == NSWindow.didMoveNotification) { return }
                log("NOTE item\(i) \(n.rawValue) frame=\(w.frame) occl=\(w.occlusionState.rawValue) screen=\(w.screen?.localizedName ?? "nil")")
            }
        }
    }
}

// MARK: - updates
var tick = 0
var updateTime: Double = 0
func updateAll() {
    tick += 1
    let t = CACurrentMediaTime()
    for i in 0..<items.count {
        series[i].append(nextValue(i, tick)); if series[i].count > 30 { series[i].removeFirst() }
        let it = items[i]
        switch MODE {
        case "image", "popup", "info":
            it.button?.image = makeImage(i, tick)
        case "view":
            let v = views[i]; v.tick = tick
            let w = widthFor(i, tick)
            if ITEMW == 0 && v.frame.width != w { v.setFrameSize(NSSize(width: w, height: v.frame.height)); it.length = w }
            v.needsDisplay = true
        case "subview":
            let v = views[i]; v.tick = tick
            let w = widthFor(i, tick)
            if v.frame.width != w { v.setFrameSize(NSSize(width: w, height: v.frame.height)); it.length = w }
            v.needsDisplay = true
        default: break
        }
    }
    updateTime += CACurrentMediaTime() - t
}

// MARK: - shots
var shotResults: [String] = []
func takeShots(ticks: [Int], label: String) {
    guard let dir = SHOTS else { return }
    let screenH = NSScreen.screens.first?.frame.height ?? 1080
    _ = screenH
    let mbRect = CGRect(x: 0, y: 0, width: NSScreen.screens.first?.frame.width ?? 1920, height: 30)
    for tk in ticks {
        // schedule 0.5 s after tick tk
        let delay = Double(tk) + 0.5 - (CACurrentMediaTime() - startTime)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) {
            let path = "\(dir)/\(label)_tick\(tick).png"
            let curTick = tick
            DispatchQueue.global().async {
                let ok = screencapture(path, rect: mbRect)
                let res = ok ? analyzeShot(path, items: max(items.count, 1)) : [:]
                DispatchQueue.main.async {
                    let line = "SHOT tick=\(curTick) ok=\(ok) path=\((path as NSString).lastPathComponent) swatches=" + res.keys.sorted().map { "item\($0):\(res[$0]!.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ","))" }.joined(separator: " ")
                    log(line); shotResults.append(line)
                    for (i, it) in items.enumerated() {
                        if let w = it.button?.window ?? it.view?.window { log("   item\(i) window.frame.x=\(w.frame.minX)...\(w.frame.maxX) approx=\(call(it, "_approximatedWindowFrame"))") }
                    }
                }
            }
        }
    }
}

// MARK: - finish
func finish() {
    reportAll("final", full: true)
    let cpu = cpuSeconds()
    log(String(format: "SUMMARY mode=%@ n=%d churn=%d patch=%d secs=%.0f ticks=%d imagesMade=%d totalDraws=%d updateMainThread=%.3fs ownCPU=%.3fs footprint=%.1fMB", MODE, items.count, CHURN ? 1 : 0, PATCH ? 1 : 0, SECS, tick, imagesMade, views.map { $0.draws }.reduce(0, +), updateTime, cpu, footprintMB()))
    if !swzCounts.isEmpty { log("SWZCOUNTS " + swzCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
    for it in items { NSStatusBar.system.removeStatusItem(it) }
    items.removeAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    log("removed all items; exit")
    exit(0)
}

// MARK: - popup test
final class PopupCtl: NSObject, NSStatusItemExpandedInterfaceDelegate, NSPopoverDelegate {
    var popover: NSPopover?
    var panel: NSPanel?
    var begins = 0, ends = 0
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        begins += 1
        log("DELEGATE didBeginExpandedInterfaceSession #\(begins) session=\(session) item.session=\(desc(statusItem.expandedInterfaceSession)) sameObj=\(statusItem.expandedInterfaceSession === session)")
        show(statusItem)
    }
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        ends += 1
        log("DELEGATE didEndExpandedInterfaceSession #\(ends) animated=\(animated) item.session=\(desc(statusItem.expandedInterfaceSession))")
        hide()
    }
    @objc func clicked(_ sender: Any?) { log("ACTION clicked (target/action path)"); if popover?.isShown == true || panel?.isVisible == true { hide() } else { show(items[0]) } }
    func show(_ it: NSStatusItem) {
        guard let b = it.button else { return }
        if POPUP == "popover" {
            let p = NSPopover(); p.behavior = .transient; p.animates = false; p.delegate = self
            let vc = NSViewController()
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
            let tf = NSTextField(labelWithString: "NSPopover default (27 SDK)"); tf.frame = NSRect(x: 16, y: 120, width: 250, height: 20); root.addSubview(tf)
            let btn = NSButton(title: "Button", target: nil, action: nil); btn.frame = NSRect(x: 16, y: 70, width: 120, height: 32); root.addSubview(btn)
            vc.view = root; p.contentViewController = vc
            p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover = p
            log("popover shown isShown=\(p.isShown) appearance=\(p.effectiveAppearance.name.rawValue) behavior=\(p.behavior.rawValue)")
        } else {
            let frameW: CGFloat = 300, frameH: CGFloat = 180
            let anchor = b.window?.frame ?? .zero
            let scr = b.window?.screen ?? NSScreen.main!
            let r = NSRect(x: min(anchor.minX, scr.frame.maxX - frameW - 8), y: scr.visibleFrame.maxY - frameH - 6, width: frameW, height: frameH)
            let pn = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            pn.isOpaque = false; pn.backgroundColor = .clear; pn.hasShadow = true; pn.level = .popUpMenu
            pn.isReleasedWhenClosed = false
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: r.size))
            glass.cornerRadius = 18
            let content = NSView(frame: NSRect(origin: .zero, size: r.size))
            let tf = NSTextField(labelWithString: "NSPanel + NSGlassEffectView"); tf.frame = NSRect(x: 16, y: 140, width: 260, height: 20); content.addSubview(tf)
            let btn = NSButton(title: "Button", target: nil, action: nil); btn.frame = NSRect(x: 16, y: 90, width: 120, height: 32); content.addSubview(btn)
            glass.contentView = content
            pn.contentView = glass
            pn.orderFrontRegardless()
            panel = pn
            log("panel shown frame=\(pn.frame) anchor(button.window.frame)=\(anchor)")
        }
    }
    func hide() {
        if let p = popover { p.performClose(nil); log("popover closed") }
        if let pn = panel { pn.orderOut(nil); log("panel ordered out") }
        popover = nil; panel = nil
    }
    func popoverDidShow(_ notification: Notification) { log("popoverDidShow") }
    func popoverDidClose(_ notification: Notification) { log("popoverDidClose") }
    func dump(label: String) {
        let win: NSWindow? = popover?.contentViewController?.view.window ?? panel
        guard let win else { log("DUMP \(label): no popup window"); return }
        var v: [String] = []; var l: [String] = []
        let root = win.contentView?.superview ?? win.contentView!
        dumpViews(root, 0, &v, maxLines: 60)
        if let rl = root.layer { dumpLayers(rl, 0, &l, maxLines: 70) }
        log("DUMP \(label) window=\(type(of: win)) #0x\(String(win.windowNumber, radix: 16)) frame=\(win.frame) styleMask=\(win.styleMask.rawValue) opaque=\(win.isOpaque) appearance=\(win.effectiveAppearance.name.rawValue) level=\(win.level.rawValue)")
        log("MARKERS \(label): " + glassMarkers(root))
        print("VIEWS:\n" + v.joined(separator: "\n"))
        print("LAYERS:\n" + l.joined(separator: "\n"))
        if let dir = SHOTS {
            let scr = win.screen ?? NSScreen.main!
            let cg = CGRect(x: win.frame.minX - 10, y: scr.frame.maxY - win.frame.maxY - 10, width: win.frame.width + 20, height: win.frame.height + 20)
            let path = "\(dir)/popup_\(label).png"
            DispatchQueue.global().async { let ok = screencapture(path, rect: cg); DispatchQueue.main.async { log("SHOT popup \(label) ok=\(ok) \(path)") } }
        }
    }
}
let popupCtl = PopupCtl()

var lastClickPoint: CGPoint? = nil
func realClick(at p: CGPoint) {
    if lastClickPoint == nil { lastClickPoint = p }
    // p in CG global coords (top-left origin). Only used on our own item.
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
    down?.post(tap: .cghidEventTap); usleep(60_000); up?.post(tap: .cghidEventTap)
    log("REALCLICK posted at \(p)")
}

// MARK: - SwiftUI MenuBarExtra (C)
final class LabelModel: ObservableObject {
    static let shared = LabelModel()
    @Published var value = 0.0
    @Published var tickN = 0
    @Published var inserted = true
    @Published var image: NSImage = NSImage(size: NSSize(width: 10, height: 10))
    var labelEvals = 0
    var timer: Timer?
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.tickN += 1; tick = self.tickN
            series[0].append(nextValue(0, self.tickN)); if series[0].count > 30 { series[0].removeFirst() }
            self.value = series[0].last ?? 0
            if COLOR && !flag("--freshimg") { self.image = makeImage(0, self.tickN) }
            if self.tickN == 3 { swiftUIReport("t3") }
            if self.tickN == 6 && flag("--open") { swiftUIOpen() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + SECS) {
            swiftUIReport("final")
            log(String(format: "SUMMARY mode=swiftui ticks=%d labelEvals=%d ownCPU=%.3fs footprint=%.1fMB", self.tickN, self.labelEvals, cpuSeconds(), footprintMB()))
            if !swzCounts.isEmpty { log("SWZCOUNTS " + swzCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
            // NOTE: flipping isInserted=false livelocks MenuBarExtra on 27.0 (mbx.swift v18/v19); exit directly, process exit removes the item
            if flag("--toggle-inserted") { InsertModel.shared.inserted = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { log("exit (item removed by process exit)"); exit(0) }
        }
        if SHOTS != nil { startTime = CACurrentMediaTime(); takeShots(ticks: [4, 5], label: "swiftui") }
    }
}
func findStatusItems() -> [NSStatusItem] {
    var r: [NSStatusItem] = []
    for w in NSApp.windows where NSStringFromClass(type(of: w)).contains("StatusBarWindow") {
        if let it = w.perform(NSSelectorFromString("statusItem"))?.takeUnretainedValue() as? NSStatusItem { r.append(it) }
    }
    return r
}
func swiftUIReport(_ tag: String) {
    let found = findStatusItems()
    items = found
    log("swiftui: found \(found.count) status item(s) via NSStatusBarWindow; windows=\(NSApp.windows.map { "\(type(of: $0))" })")
    reportAll(tag, full: true)
    if let b = found.first?.button {
        var v: [String] = []; dumpViews(b, 0, &v, maxLines: 30); print("SWIFTUI BUTTON VIEWS:\n" + v.joined(separator: "\n"))
        log("swiftui button image=\(desc(b.image)) title='\(b.title)' subviews=\(b.subviews.count)")
    }
}
func swiftUIOpen() {
    guard let it = findStatusItems().first else { return }
    log("swiftui: expandedInterfaceDelegate=\(desc(it.expandedInterfaceDelegate))")
    if REALCLICK, let dir = SHOTS {
        let path = "\(dir)/swiftui_locate.png"
        DispatchQueue.global().async {
            _ = screencapture(path, rect: CGRect(x: 0, y: 0, width: 1920, height: 30))
            let res = analyzeShot(path, items: 1)
            DispatchQueue.main.async {
                let wf = it.button?.window?.frame ?? .zero
                if let r = res[0]?.first, CGFloat(r.lowerBound) >= wf.minX, CGFloat(r.upperBound) <= wf.maxX { realClick(at: CGPoint(x: Double(r.lowerBound) + 3, y: 15)) } else { log("REALCLICK skipped res=\(res) wf=\(wf)") }
            }
        }
    } else {
        log("swiftui: performClick on MenuBarExtra button")
        it.button?.performClick(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        let wins = NSApp.windows.filter { $0.isVisible && !NSStringFromClass(type(of: $0)).contains("StatusBarWindow") }
        log("swiftui: visible windows after click: \(wins.map { "\(type(of: $0)) \($0.frame)" }) session=\(desc(it.expandedInterfaceSession))")
        if let w = wins.first, let root = w.contentView?.superview ?? w.contentView {
            log("MARKERS menubarextra-window: " + glassMarkers(root))
            var v: [String] = []; dumpViews(root, 0, &v, maxLines: 50); print("MBX VIEWS:\n" + v.joined(separator: "\n"))
            var l: [String] = []; if let rl = root.layer { dumpLayers(rl, 0, &l, maxLines: 50) }; print("MBX LAYERS:\n" + l.joined(separator: "\n"))
            if let dir = SHOTS {
                let scr = w.screen ?? NSScreen.main!
                let cg = CGRect(x: w.frame.minX - 10, y: scr.frame.maxY - w.frame.maxY - 10, width: w.frame.width + 20, height: w.frame.height + 20)
                DispatchQueue.global().async { let ok = screencapture("\(dir)/popup_menubarextra.png", rect: cg); log("SHOT menubarextra ok=\(ok)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { it.expandedInterfaceSession?.cancel(); it.button?.performClick(nil); log("swiftui: closed (cancel + toggle)") }
    }
}
struct ProbeLabel: View {
    @ObservedObject var model = LabelModel.shared
    @Environment(\.systemPrefersReducedResourceUsage) var reduced
    @Environment(\.colorScheme) var scheme
    var body: some View {
        model.labelEvals += 1
        return HStack(spacing: 2) {
            if COLOR { if flag("--freshimg") { Image(nsImage: makeImage(0, model.tickN)) } else { Image(nsImage: model.image) } } else {
                Image(systemName: "cpu")
                Text(String(format: "%2.0f%%", model.value)).monospacedDigit()
            }
        }
        .onAppear { log("swiftui label onAppear systemPrefersReducedResourceUsage=\(reduced) colorScheme=\(scheme)"); model.start() }
        .onChange(of: reduced) { _, n in log("systemPrefersReducedResourceUsage -> \(n)") }
    }
}
struct ProbePanel: View {
    @Environment(\.systemPrefersReducedResourceUsage) var reduced
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MenuBarExtra .window").font(.headline)
            Text("reducedResourceUsage=\(reduced ? "true" : "false")")
            Button("Button") {}
        }.padding(16).frame(width: 260)
        .onAppear { log("swiftui panel onAppear systemPrefersReducedResourceUsage=\(reduced)") }
    }
}
final class InsertModel: ObservableObject { static let shared = InsertModel(); @Published var inserted = true }
struct ProbeApp: App {
    // NOTE: binding isInserted to the per-tick LabelModel observed by the App livelocks MenuBarExtra on 27.0 (see mbx.swift variants 9/11/13)
    @ObservedObject var ins = InsertModel.shared
    init() { NSApplication.shared.setActivationPolicy(.accessory); if PATCH { applyTilingPatch() }; if SWZ { installSwizzles() } }
    var body: some Scene {
        MenuBarExtra(isInserted: $ins.inserted) { ProbePanel() } label: { ProbeLabel() }
            .menuBarExtraStyle(.window)
    }
}
struct ProbeAppNoInsert: App {
    init() { NSApplication.shared.setActivationPolicy(.accessory); if PATCH { applyTilingPatch() }; if SWZ { installSwizzles() } }
    var body: some Scene {
        MenuBarExtra { ProbePanel() } label: { ProbeLabel() }
            .menuBarExtraStyle(.window)
    }
}

// MARK: - main
var startTime = CACurrentMediaTime()
if MODE == "swiftui" {
    series = [[]]
    log("mode=swiftui secs=\(SECS) patch=\(PATCH)")
    if flag("--no-inserted") { ProbeAppNoInsert.main() } else { ProbeApp.main() }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
log("OS \(ProcessInfo.processInfo.operatingSystemVersionString) mode=\(MODE) n=\(N) secs=\(SECS) churn=\(CHURN) patch=\(PATCH) color=\(COLOR) itemw=\(ITEMW) bundle=\(Bundle.main.bundleIdentifier ?? "nil") thickness=\(NSStatusBar.system.thickness)")
if PATCH { applyTilingPatch() }
if SWZ { installSwizzles() }

if MODE == "info" {
    for (c, s) in [("NSSceneStatusItem", "scene:didUpdateSettings:"), ("NSSceneStatusItem", "_updateForStatusItemSceneDiff:"), ("NSSceneStatusItem", "_updateForVariantSceneDiff:"), ("NSSceneStatusItem", "scene:handleActions:"), ("NSSceneStatusItem", "_setVisible:temporary:"), ("NSSceneStatusItem", "hostWindowID"), ("NSStatusItem", "_isHidden"), ("NSStatusItem", "_approximatedWindowFrame"), ("NSStatusItem", "_setHidden:"), ("NSStatusItem", "_hideFromBar"), ("NSStatusItemScene", "updateSettings:"), ("NSStatusItemScene", "updateStatusItemOnBackgroundThread:"), ("NSStatusItemScene", "hostSettings"), ("NSStatusItemScene", "clientSettings"), ("NSWindow", "_needsTilingConstraintUpdate"), ("NSStatusBarWindow", "_needsTilingConstraintUpdate"), ("NSSceneStatusItem", "_beginExpandedInterfaceSession:"), ("NSSceneStatusItem", "_endExpandedInterfaceSession:animate:"), ("NSSceneStatusItem", "_requestExpandedInterfaceSession")] {
        log("enc \(c).\(s) = \(encoding(c, s))")
    }
}

let count = (MODE == "popup" || MODE == "info") ? 1 : N
series = Array(repeating: [], count: count)
for i in 0..<count {
    let w = widthFor(i, 0)
    let it: NSStatusItem
    switch MODE {
    case "view":
        it = NSStatusBar.system.statusItem(withLength: w)
        let v = WidgetView(frame: NSRect(x: 0, y: 0, width: w, height: NSStatusBar.system.thickness)); v.idx = i
        it.view = v; views.append(v)
    case "subview":
        it = NSStatusBar.system.statusItem(withLength: w)
        let v = WidgetView(frame: NSRect(x: 0, y: 0, width: w, height: NSStatusBar.system.thickness)); v.idx = i
        it.button?.addSubview(v); it.button?.image = NSImage(); views.append(v)
    default:
        it = NSStatusBar.system.statusItem(withLength: ITEMW > 0 ? CGFloat(ITEMW) : NSStatusItem.variableLength)
    }
    it.autosaveName = "mbprobe.item\(i)"
    it.behavior = []
    if !it.isVisible { log("item\(i) came up isVisible=false (persisted autosave visibility); forcing isVisible=true"); it.isVisible = true }
    items.append(it)
}
updateAll()
var monitors: [Any] = []
if MODE == "popup" {
    if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown], handler: { e in log("LOCALMON \(e.type.rawValue) window=\(e.window.map { "\(type(of: $0))" } ?? "nil") loc=\(e.locationInWindow)"); return e }) { monitors.append(m) }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { e in log("GLOBALMON leftMouseDown at \(NSEvent.mouseLocation)") }) { monitors.append(m) }
    if DELEGATE { items[0].expandedInterfaceDelegate = popupCtl; log("expandedInterfaceDelegate set; session=\(desc(items[0].expandedInterfaceSession))") }
    else { items[0].button?.target = popupCtl; items[0].button?.action = #selector(PopupCtl.clicked(_:)) }
}
startTime = CACurrentMediaTime()
let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
    updateAll()
    if REPORT > 0 && tick % Int(REPORT) == 0 { reportAll("t\(tick)") }
}
RunLoop.main.add(timer, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    for (i, it) in items.enumerated() { observe(i, it) }
    reportAll("t1", full: true)
    menubarCGWindows().forEach { log($0) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { reportAll("t3") }
if SHOTS != nil { takeShots(ticks: [4, 5, Int(min(SECS - 2, 9))], label: "\(MODE)\(CHURN ? "_churn" : "")_n\(count)") }

if MODE == "popup" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        log("popup: performClick on item0 button (delegate=\(DELEGATE))")
        items[0].button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            log("popup: after performClick begins=\(popupCtl.begins) session=\(desc(items[0].expandedInterfaceSession)) popoverShown=\(popupCtl.popover?.isShown ?? false) panelVisible=\(popupCtl.panel?.isVisible ?? false)")
            if popupCtl.begins == 0 && DELEGATE && REALCLICK, let dir = SHOTS {
                // locate own swatch in a fresh screenshot and click it
                let path = "\(dir)/popup_locate.png"
                DispatchQueue.global().async {
                    _ = screencapture(path, rect: CGRect(x: 0, y: 0, width: 1920, height: 30))
                    let res = analyzeShot(path, items: 1)
                    DispatchQueue.main.async {
                        let wf = items[0].button?.window?.frame ?? .zero
                        if let r = res[0]?.first, CGFloat(r.lowerBound) >= wf.minX, CGFloat(r.upperBound) <= wf.maxX { realClick(at: CGPoint(x: Double(r.lowerBound) + 3, y: 15)) } else { log("REALCLICK: own swatch not found inside own window frame \(wf) (res=\(res)); skipped") }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            log("popup: t+3 begins=\(popupCtl.begins) session=\(desc(items[0].expandedInterfaceSession))")
            popupCtl.dump(label: "\(POPUP)\(DELEGATE ? "_delegate" : "_action")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if let pt = lastClickPoint, flag("--click2") || flag("--clickaway") {
                let p2 = flag("--clickaway") ? CGPoint(x: 700, y: 15) : pt
                log("popup: second real click at \(p2) (\(flag("--clickaway") ? "empty menu bar area" : "own item again"))")
                realClick(at: p2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { log("popup: after 2nd real click begins=\(popupCtl.begins) ends=\(popupCtl.ends) session=\(desc(items[0].expandedInterfaceSession)) popoverShown=\(popupCtl.popover?.isShown ?? false) panelVisible=\(popupCtl.panel?.isVisible ?? false)") }
            } else if DELEGATE, let s = items[0].expandedInterfaceSession { log("popup: calling session.cancel()"); s.cancel() }
            else { log("popup: no session; closing directly"); popupCtl.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                log("popup: after cancel begins=\(popupCtl.begins) ends=\(popupCtl.ends) session=\(desc(items[0].expandedInterfaceSession))")
                // second round: click again to test toggle / re-begin
                items[0].button?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    log("popup: 2nd performClick begins=\(popupCtl.begins) ends=\(popupCtl.ends) session=\(desc(items[0].expandedInterfaceSession))")
                    items[0].button?.performClick(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        log("popup: 3rd performClick (toggle) begins=\(popupCtl.begins) ends=\(popupCtl.ends) session=\(desc(items[0].expandedInterfaceSession))")
                        popupCtl.hide()
                    }
                }
            }
        }
    }
}
if let shr = opt("--shrink").flatMap(Double.init) {
    // shrink the first half of the items so overflowed ones can come back; then restore
    var shrunk: [Int: CGFloat] = [:]
    func setW(_ i: Int, _ w: CGFloat) {
        items[i].length = w
        if i < views.count { views[i].setFrameSize(NSSize(width: w, height: views[i].frame.height)) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + shr) {
        log("SHRINK: items 0..<\(items.count / 2) -> 24pt")
        for i in 0..<(items.count / 2) { shrunk[i] = items[i].length; setW(i, 24) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { reportAll("after-shrink") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            log("RESTORE: items 0..<\(items.count / 2) -> 200pt")
            for (i, w) in shrunk { setW(i, w) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { reportAll("after-restore") }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + SECS) { finish() }
signal(SIGTERM, SIG_IGN)
let sigsrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigsrc.setEventHandler { log("SIGTERM"); finish() }
sigsrc.resume()
app.run()
