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
        #if DEBUG
        // Test hook: close the popup the way the close button does, after N
        // seconds, so "does the app exit when the popup closes" can be
        // checked without UI automation. Debug builds only. Launch with
        // `open -a contextGIST.app --env CONTEXTGIST_TEST_AUTOCLOSE_AFTER=3`;
        // add `--env CONTEXTGIST_TEST_AUTOCLOSE_VIA=escape` to use the Escape
        // key's path (`window.close()`) instead of the close button's.
        let env = ProcessInfo.processInfo.environment
        if let delay = env["CONTEXTGIST_TEST_AUTOCLOSE_AFTER"].flatMap(Double.init) {
            let viaEscape = env["CONTEXTGIST_TEST_AUTOCLOSE_VIA"] == "escape"
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                if viaEscape { window?.close() } else { window?.performClose(nil) }
            }
        }
        #endif
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
