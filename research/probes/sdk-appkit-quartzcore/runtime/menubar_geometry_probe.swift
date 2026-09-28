// Read-only: compare NSStatusBar.thickness with the menu bar height implied by NSScreen frames.
import AppKit
MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    print("NSStatusBar.system.thickness =", NSStatusBar.system.thickness)
    print("NSMenu.menuBarVisible() =", NSMenu.menuBarVisible())
    print("NSApp.mainMenu height (menuBarHeight) =", NSApp.mainMenu?.menuBarHeight ?? -1)
    for s in NSScreen.screens {
        let f = s.frame, v = s.visibleFrame
        print("screen frame =", f, " visibleFrame =", v, " menubar gap (frame.maxY - visibleFrame.maxY) =", f.maxY - v.maxY,
              " safeAreaInsets.top =", s.safeAreaInsets.top, " auxTopLeft =", String(describing: s.auxiliaryTopLeftArea), " scale =", s.backingScaleFactor)
    }
}
