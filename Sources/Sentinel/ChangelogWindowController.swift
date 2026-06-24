import AppKit
import SwiftUI

/// Owns the single "What's New" window. Created on first request and reused
/// thereafter — closing hides it rather than tearing it down, so reopening is
/// instant and keeps the already-loaded content.
@MainActor
final class ChangelogWindowController {
    private var window: NSWindow?

    func show() {
        Log.ui.info("Opening changelog window")

        if let window {
            present(window)
            return
        }

        let controller = NSHostingController(rootView: ChangelogView())
        let window = NSWindow(contentViewController: controller)
        window.title = "What's New"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 560))
        // AppKit releases a window on close by default, which would dangle our
        // reference; keep the single instance alive across closes instead.
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        // An accessory (LSUIElement) app must activate for its window to come to
        // the front — mirrors the Sparkle update window handling in AppDelegate.
        NSApp.activate()
    }
}
