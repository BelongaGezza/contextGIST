import AppKit
import SwiftUI

/// Owns the single popup window a Services invocation opens. Holds the
/// selected text (via `RsvpView`/`RsvpPlayer`) only as long as the window is
/// open — `onClose` is invoked from `windowWillClose`, and nothing here is
/// written to disk or handed back to the pasteboard.
final class PopupController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(text: String, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "contextGIST"
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        self.window = window

        super.init()
        window.delegate = self
        window.contentView = NSHostingView(rootView: RsvpView(text: text, onEscape: { [weak window] in
            window?.close()
        }))
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
