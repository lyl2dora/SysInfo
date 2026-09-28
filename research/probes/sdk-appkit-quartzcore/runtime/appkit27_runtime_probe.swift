// Runtime probe for macOS 27 AppKit UI APIs. No status items are created, no windows are ordered on screen.
import AppKit

final class Rounded: NSView {
    var cfg: NSViewCornerConfiguration?
    var changes = 0
    override var cornerConfiguration: NSViewCornerConfiguration? { cfg }
    override func viewDidChangeEffectiveCornerRadii() { super.viewDidChangeEffectiveCornerRadii(); changes += 1 }
}

func radii(_ r: NSViewCornerRadii?) -> String {
    guard let r else { return "nil" }
    return String(format: "TL=%.2f TR=%.2f BL=%.2f BR=%.2f", r.topLeft, r.topRight, r.bottomLeft, r.bottomRight)
}

@MainActor func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let pi = ProcessInfo.processInfo
    print("OS:", pi.operatingSystemVersionString)

    print("\n== Runtime class presence")
    for c in ["NSGlassEffectView","NSGlassEffectContainerView","NSBackgroundExtensionView","NSStatusItemExpandedInterfaceSession",
              "NSViewCornerConfiguration","NSViewCornerRadius","NSViewCornerRadii","NSRefreshController","NSScrollEdgeEffectStyle",
              "NSItemBadge","NSViewLayoutRegion","NSTextSelectionManager","NSStatusItemAuxiliaryHostingView","NSMenuBarNavigationSceneExtension",
              "NSVisualEffectView","NSHostingView"] {
        print(String(format: "%-40@ %@", c as NSString, NSClassFromString(c) != nil ? "present" : "ABSENT"))
    }

    print("\n== Selector presence")
    let sels: [(AnyClass, String)] = [
        (NSStatusItem.self, "expandedInterfaceDelegate"), (NSStatusItem.self, "setExpandedInterfaceDelegate:"),
        (NSStatusItem.self, "expandedInterfaceSession"), (NSStatusItem.self, "view"), (NSStatusItem.self, "setView:"),
        (NSGlassEffectView.self, "effectIsInteractive"), (NSGlassEffectView.self, "setEffectIsInteractive:"),
        (NSMenuItem.self, "preferredImageVisibility"), (NSView.self, "cornerConfiguration"), (NSView.self, "effectiveCornerRadii"),
        (NSView.self, "invalidateCornerConfiguration"), (NSSegmentedControl.self, "role"), (NSControl.self, "addTarget:action:forControlEvents:"),
        (NSScrollView.self, "refreshController"), (NSScreen.self, "touchCapabilities"), (NSTextField.self, "borderShape"),
        (NSButton.self, "tintProminence"), (NSButton.self, "borderShape"), (NSView.self, "prefersCompactControlSizeMetrics")]
    for (cls, s) in sels {
        print(String(format: "%-22@ %-38@ %@", NSStringFromClass(cls) as NSString, s as NSString, cls.instancesRespond(to: NSSelectorFromString(s)) ? "yes" : "NO"))
    }

    print("\n== NSStatusBar (read-only)")
    print("system.thickness =", NSStatusBar.system.thickness, " isVertical =", NSStatusBar.system.isVertical)

    print("\n== NSGlassEffectView defaults")
    let g = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    print("style =", g.style.rawValue, "(0=regular,1=clear)  cornerRadius =", g.cornerRadius, " tintColor =", String(describing: g.tintColor), " effectIsInteractive =", g.effectIsInteractive)
    print("glass.cornerConfiguration =", String(describing: g.cornerConfiguration), " effectiveCornerRadii =", radii(g.effectiveCornerRadii))
    g.effectIsInteractive = true
    print("after set effectIsInteractive =", g.effectIsInteractive)

    print("\n== Corner configuration resolution inside an offscreen window")
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    print("window.contentView.cornerConfiguration =", String(describing: win.contentView?.cornerConfiguration), " effective =", radii(win.contentView?.effectiveCornerRadii))
    g.cornerRadius = 24
    let inner = Rounded(frame: NSRect(x: 8, y: 8, width: 184, height: 104))
    inner.cfg = .corners(radius: .containerConcentric(4))
    let content = NSView(frame: g.bounds)
    content.addSubview(inner)
    g.contentView = content
    win.contentView?.addSubview(g)
    let fixed = Rounded(frame: NSRect(x: 220, y: 10, width: 100, height: 40))
    fixed.cfg = .capsule
    win.contentView?.addSubview(fixed)
    let fixed2 = Rounded(frame: NSRect(x: 220, y: 60, width: 100, height: 40))
    fixed2.cfg = .uniformCorners(radius: .fixed(10))
    win.contentView?.addSubview(fixed2)
    win.contentView?.layoutSubtreeIfNeeded()
    win.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    print("glass(cornerRadius=24).effectiveCornerRadii =", radii(g.effectiveCornerRadii))
    print("inner containerConcentric(min 4) inset 8pt in glass r=24 ->", radii(inner.effectiveCornerRadii), " didChange callbacks =", inner.changes)
    print("capsule 100x40 ->", radii(fixed.effectiveCornerRadii), " callbacks =", fixed.changes)
    print("uniform fixed(10) ->", radii(fixed2.effectiveCornerRadii), " callbacks =", fixed2.changes)
    inner.invalidateCornerConfiguration()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    print("after invalidate: inner ->", radii(inner.effectiveCornerRadii))

    print("\n== NSMenuItem image visibility")
    let mi = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    print("default preferredImageVisibility =", mi.preferredImageVisibility.rawValue, "(0=automatic,1=visible,2=hidden)")
    let hdr = NSMenuItem.sectionHeader(title: "Sensors")
    print("sectionHeader isSectionHeader =", hdr.isSectionHeader)

    print("\n== Controls")
    let b = NSButton(title: "Glass", target: nil, action: nil)
    b.bezelStyle = .glass
    print("NSButton bezelStyle .glass rawValue =", b.bezelStyle.rawValue, " tintProminence =", b.tintProminence.rawValue, " borderShape =", b.borderShape.rawValue)
    b.controlSize = .extraLarge
    print("controlSize .extraLarge =", b.controlSize.rawValue, " intrinsic =", b.intrinsicContentSize)
    let seg = NSSegmentedControl(labels: ["1s","2s","5s"], trackingMode: .selectOne, target: nil, action: nil)
    print("NSSegmentedControl default role =", seg.role.rawValue, "(0=automatic,1=tabs,2=valueSelection)")
    let tf = NSTextField(string: "x")
    print("NSTextField borderShape default =", tf.borderShape.rawValue)

    print("\n== NSScreen")
    for s in NSScreen.screens {
        print("screen", s.localizedName, "touchCapabilities =", s.touchCapabilities.rawValue, " CGDirectDisplayID =", s.cgDirectDisplayID ?? 0, " backingScale =", s.backingScaleFactor, " maxEDR =", s.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }

    print("\n== SF Symbols for a system monitor (NSImage(systemSymbolName:variableValue:))")
    let names = ["cpu","cpu.fill","memorychip","memorychip.fill","gpu","thermometer.medium","thermometer.variable","fan","fan.fill",
                 "gauge.with.dots.needle.33percent","gauge.with.needle","internaldrive","externaldrive","network","wifi","antenna.radiowaves.left.and.right",
                 "arrow.up.arrow.down","battery.100percent","battery.100percent.bolt","bolt.fill","powerplug","powerplug.portrait","bluetooth",
                 "chart.bar.fill","chart.line.uptrend.xyaxis","waveform.path.ecg","clock","speedometer","sensor","dial.medium","square.stack.3d.up"]
    var missing: [String] = []
    for n in names {
        if NSImage(systemSymbolName: n, variableValue: 0.5, accessibilityDescription: nil) == nil { missing.append(n) }
    }
    print("checked \(names.count), missing: \(missing)")
    let cfgDraw = NSImage.SymbolConfiguration(variableValueMode: .draw)
    let cfgColor = NSImage.SymbolConfiguration(variableValueMode: .color)
    for n in ["thermometer.variable","wifi","gauge.with.needle","speaker.wave.3","cellularbars"] {
        let img = NSImage(systemSymbolName: n, variableValue: 0.4, accessibilityDescription: nil)
        let d = img?.withSymbolConfiguration(cfgDraw)
        let c = img?.withSymbolConfiguration(cfgColor)
        print(String(format: "%-22@ base=%@ draw=%@ color=%@ template=%@", n as NSString, img == nil ? "nil" : "ok", d == nil ? "nil" : "ok", c == nil ? "nil" : "ok", (img?.isTemplate ?? false) ? "yes" : "no"))
    }

    print("\n== NSVisualEffectView (not deprecated)")
    let ve = NSVisualEffectView()
    print("material default =", ve.material.rawValue, " blendingMode =", ve.blendingMode.rawValue, " state =", ve.state.rawValue)

    print("\n== Appearance / accessibility")
    print("effectiveAppearance =", app.effectiveAppearance.name.rawValue)
    let ws = NSWorkspace.shared
    print("reduceTransparency =", ws.accessibilityDisplayShouldReduceTransparency, " increaseContrast =", ws.accessibilityDisplayShouldIncreaseContrast, " reduceMotion =", ws.accessibilityDisplayShouldReduceMotion)
    win.close()
}

MainActor.assumeIsolated { run() }
