// 菜单栏排序 probe（docs/design/menubar-order.md §3）。
//
// 一个独立的 accessory app（bundle id local.probe.mborder，只读写自己的 defaults 域），
// 按命令行给的步骤脚本创建、移除 status item，并报告各 item 的屏幕位置、
// 自己域里的 NSStatusItem* 键，以及菜单栏上所有 status 窗口的先后（看与其他 app 的 item 怎么穿插）。
//
// 用法：mborder.app/Contents/MacOS/mborder --steps "clear;create:a,b,c;wait:1.5;report:t0;quit"
// 步骤（分号分隔）：
//   clear                      删掉本域所有 "NSStatusItem" 开头的键
//   pref:a=200,b=400           写 "NSStatusItem Preferred Position <名字>" = 数值（创建前写）
//   create:a,b,c               依次创建；名字前加 ~ 表示不设 autosaveName
//   remove:a,b | remove:all    移除
//   rename:a=a2                改一个已存在 item 的 autosaveName
//   nil:a,b                    把 autosaveName 设为 nil（文档：清除已保存的信息）
//   prefslots:b,a,c            按当前屏幕位置算出各 item 距右边缘的距离，按给定左→右顺序写成 Preferred Position 键
//   wait:秒
//   report:标签                位置 + 本域键 + 全菜单栏 status 窗口
//   watch:秒                   每 0.25 s 轮询，顺序、x 或本域键变化时打印（用于 ⌘ 拖动）
//   drag:a>b                   用 CGEvent 模拟 ⌘ 拖动 a 到 b 的左边缘（修饰键成对发送）
//   quit

import AppKit
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date()
func log(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s) }

let bundleID = Bundle.main.bundleIdentifier ?? "local.probe.mborder"
let prefix = "NSStatusItem"

func ownKeys() -> [String: String] {
    let list = (CFPreferencesCopyKeyList(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? []
    var out: [String: String] = [:]
    for k in list where k.hasPrefix(prefix) {
        let v = CFPreferencesCopyAppValue(k as CFString, bundleID as CFString)
        out[k] = v.map { "\($0)" } ?? "nil"
    }
    return out
}

func call(_ obj: NSObject, _ sel: String) -> String {
    let s = NSSelectorFromString(sel)
    guard obj.responds(to: s) else { return "n/a" }
    return obj.value(forKey: sel).map { "\($0)" } ?? "nil"
}

var items: [(name: String, item: NSStatusItem)] = []

func create(_ raw: String) {
    let noSave = raw.hasPrefix("~")
    let name = noSave ? String(raw.dropFirst()) : raw
    let it = NSStatusBar.system.statusItem(withLength: 34)
    if !noSave { it.autosaveName = name }
    it.behavior = .removalAllowed
    it.isVisible = true
    it.button?.title = name.uppercased()
    items.append((name, it))
    log("created \(name) autosave=\(it.autosaveName ?? "nil") _systemInsertOrder=\(call(it, "_systemInsertOrder")) _priority=\(call(it, "_priority")) prefPosKey=\(call(it, "_preferredPositionDefaultsKey"))")
}

func remove(_ name: String) {
    let targets = name == "all" ? items.map(\.name) : [name]
    for n in targets {
        guard let i = items.firstIndex(where: { $0.name == n }) else { continue }
        NSStatusBar.system.removeStatusItem(items[i].item)
        items.remove(at: i)
        log("removed \(n)")
    }
}

func frame(_ it: NSStatusItem) -> CGRect? {
    guard let w = it.button?.window ?? it.view?.window, w.frame.width > 0 else { return nil }
    return w.frame
}

/// 本 app 各 item 从左到右，形如 "c(1180) b(1214) a(1248)"。
func ownOrder() -> String {
    items.compactMap { e -> (String, CGFloat)? in frame(e.item).map { (e.name, $0.minX) } }
        .sorted { $0.1 < $1.1 }
        .map { "\($0.0)(\(Int($0.1)))" }
        .joined(separator: " ")
}

/// 菜单栏上所有 app 的 status item 从左到右（27 的 status item 窗口不在 CGWindowList 里，改读各 app 的
/// AXExtrasMenuBar；需要辅助功能授权）。本 app 的标成 *名字，其他 app 用序号代替名字（输出不进库也不写 app 名）。
func barOrder() -> String {
    guard AXIsProcessTrusted() else { return "(AX not trusted)" }
    func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    let me = ProcessInfo.processInfo.processIdentifier
    var rows: [(CGFloat, String)] = []
    var appIndex: [pid_t: Int] = [:]
    for app in NSWorkspace.shared.runningApplications {
        let pid = app.processIdentifier
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.3)
        guard let extras = attr(el, "AXExtrasMenuBar"), let kids = attr(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { continue }
        for k in kids {
            var p = CGPoint.zero
            if let v = attr(k, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
            let tag: String
            if pid == me {
                tag = "*" + ((attr(k, kAXTitleAttribute) as? String)?.lowercased() ?? "?")
            } else {
                if appIndex[pid] == nil { appIndex[pid] = appIndex.count + 1 }
                switch app.bundleIdentifier {
                case "zone.lyl.sysinfo.dev": tag = "dev"
                // 第二个 probe（充当「其他 app」）显示它自己的 item 名
                case "local.probe.mborder2": tag = "X:" + ((attr(k, kAXTitleAttribute) as? String)?.lowercased() ?? "?")
                default: tag = "app\(appIndex[pid]!)"
                }
            }
            rows.append((p.x, "\(tag)@\(Int(p.x))"))
        }
    }
    return rows.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
}

func report(_ tag: String) {
    log("---- report \(tag) ----")
    log("own L→R: \(ownOrder())")
    log("bar L→R: \(barOrder())")
    let keys = ownKeys()
    log("own keys (\(keys.count)): " + keys.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
    for e in items {
        log("  \(e.name) [autosave=\(e.item.autosaveName ?? "nil")]: frame=\(frame(e.item).map { "\($0)" } ?? "nil") visible=\(e.item.isVisible) approx=\(call(e.item, "_approximatedWindowFrame"))")
    }
}

func drag(_ from: String, _ to: String) {
    guard let a = items.first(where: { $0.name == from }), let b = items.first(where: { $0.name == to }),
        let fa = frame(a.item), let fb = frame(b.item), let screen = NSScreen.screens.first
    else { log("drag: item missing"); return }
    // CG 坐标原点在主屏左上角。
    let h = screen.frame.height
    cmdDrag(from, to, CGPoint(x: fa.midX, y: h - fa.midY), CGPoint(x: fb.minX + 3, y: h - fb.midY))
}

func dragBy(_ from: String, _ dx: CGFloat) {
    guard let a = items.first(where: { $0.name == from }), let fa = frame(a.item), let screen = NSScreen.screens.first
    else { log("dragby: item missing"); return }
    let h = screen.frame.height
    cmdDrag(from, "\(dx) pt", CGPoint(x: fa.midX, y: h - fa.midY), CGPoint(x: fa.midX + dx, y: h - fa.midY))
}

func cmdDrag(_ from: String, _ to: String, _ start: CGPoint, _ end: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(30_000) }
    let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
    cmdDown?.flags = .maskCommand
    post(cmdDown)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
    down?.flags = .maskCommand
    post(down)
    let steps = 20
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
        let m = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
        m?.flags = .maskCommand
        post(m)
    }
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
    up?.flags = .maskCommand
    post(up)
    let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
    cmdUp?.flags = []
    post(cmdUp)
    let residual = CGEventSource.flagsState(.hidSystemState)
    log("drag \(from) → left of \(to): \(start) → \(end); residual flags=0x\(String(residual.rawValue, radix: 16)) cmd=\(residual.contains(.maskCommand))")
}

/// 本 app 各 item 当前「距屏幕右边缘」的距离，从大到小（= 从左到右）；同时记下来给移除后的 prefslots 用。
var lastSlots: [CGFloat] = []
func currentSlots() -> [CGFloat] {
    let maxX = NSScreen.screens.first?.frame.maxX ?? 0
    let s = items.compactMap { frame($0.item).map { maxX - $0.maxX } }.sorted(by: >)
    if !s.isEmpty { lastSlots = s }
    return s
}

// MARK: - 步骤执行

let args = CommandLine.arguments
guard let si = args.firstIndex(of: "--steps"), si + 1 < args.count else {
    print("usage: mborder --steps \"clear;create:a,b,c;wait:1.5;report:t0;quit\"")
    exit(2)
}
let steps = args[si + 1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

func run(_ index: Int) {
    guard index < steps.count else { log("steps done"); NSApp.terminate(nil); return }
    let step = steps[index]
    let (op, arg): (String, String) = {
        if let c = step.firstIndex(of: ":") { return (String(step[..<c]), String(step[step.index(after: c)...])) }
        return (step, "")
    }()
    let next = { (delay: Double) in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(index + 1) } }
    switch op {
    case "clear":
        let keys = ownKeys().keys
        for k in keys { CFPreferencesSetAppValue(k as CFString, nil, bundleID as CFString) }
        CFPreferencesAppSynchronize(bundleID as CFString)
        log("cleared \(keys.count) keys")
        next(0)
    case "pref":
        for kv in arg.split(separator: ",") {
            let p = kv.split(separator: "=")
            guard p.count == 2, let v = Double(p[1]) else { continue }
            CFPreferencesSetAppValue("\(prefix) Preferred Position \(p[0])" as CFString, v as CFNumber, bundleID as CFString)
        }
        CFPreferencesAppSynchronize(bundleID as CFString)
        log("pref written: \(arg)")
        next(0)
    case "create":
        arg.split(separator: ",").forEach { create(String($0)) }
        next(0)
    case "remove":
        arg.split(separator: ",").forEach { remove(String($0)) }
        next(0)
    case "rename":
        let p = arg.split(separator: "=").map(String.init)
        if p.count == 2, let e = items.first(where: { $0.name == p[0] }) {
            e.item.autosaveName = p[1]
            log("renamed autosave \(p[0]) → \(p[1])")
        }
        next(0)
    case "nil":
        // 文档（NSStatusItem.h）：autosaveName 设为 nil 会重置为自动名并「clears saved information」。
        for n in arg.split(separator: ",").map(String.init) {
            guard let e = items.first(where: { $0.name == n }) else { continue }
            e.item.autosaveName = nil
            log("nil autosave \(n) → now \(e.item.autosaveName ?? "nil")")
        }
        next(0)
    case "slots":
        log("slots saved \(currentSlots())")
        next(0)
    case "prefslots":
        // 对照路线：取本 app 各 item 当前「距屏幕右边缘」的距离，按给定的左→右顺序重新分配后写成 Preferred Position 键。
        let names = arg.split(separator: ",").map(String.init)
        let live = currentSlots()
        let slots = live.isEmpty ? lastSlots : live
        guard slots.count == names.count else { log("prefslots: \(slots.count) slots for \(names.count) names"); next(0); return }
        for (n, v) in zip(names, slots) {
            CFPreferencesSetAppValue("\(prefix) Preferred Position \(n)" as CFString, v as CFNumber, bundleID as CFString)
        }
        CFPreferencesAppSynchronize(bundleID as CFString)
        log("prefslots written L→R \(names) = \(slots)")
        next(0)
    case "wait":
        next(Double(arg) ?? 1)
    case "report":
        report(arg)
        next(0)
    case "watch":
        let until = Date().addingTimeInterval(Double(arg) ?? 30)
        var last = ""
        func poll() {
            let snap = ownOrder() + " | " + ownKeys().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            if snap != last { log("watch: \(snap)"); last = snap }
            if Date() < until { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll) } else { next(0) }
        }
        poll()
    case "drag":
        let p = arg.split(separator: ">").map(String.init)
        if p.count == 2 { drag(p[0], p[1]) }
        next(0.5)
    case "dragby":
        // dragby:a=80：把 a 往右（负数往左）拖动 80 pt，用于拖过别的 app 的 item。
        let p = arg.split(separator: "=").map(String.init)
        if p.count == 2, let dx = Double(p[1]) { dragBy(p[0], CGFloat(dx)) }
        next(0.5)
    case "quit":
        log("quit")
        NSApp.terminate(nil)
    default:
        log("unknown step \(step)")
        next(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
log("mborder \(bundleID) pid=\(ProcessInfo.processInfo.processIdentifier) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
DispatchQueue.main.async { run(0) }
app.run()
