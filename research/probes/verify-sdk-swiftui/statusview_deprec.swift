import AppKit
@MainActor func f(_ item: NSStatusItem) { item.view = NSView(); item.target = nil; item.action = nil }
