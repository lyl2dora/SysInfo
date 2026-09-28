import AppKit

@MainActor
final class Handler: NSObject {
    @objc func clicked(_ sender: Any?) {}
}

@MainActor
func probe(_ item: NSStatusItem, _ h: Handler) {
    // Un-deprecated in the macOS 27 SDK (were API_DEPRECATED 10.0-10.14 in 26.5 SDK)
    item.view = NSView(frame: .init(x: 0, y: 0, width: 40, height: 22))
    item.target = h
    item.action = #selector(Handler.clicked(_:))
    // Still deprecated in both
    item.title = "x"
}
