import AppKit

/// Handles the "Speed Read with contextGIST" Services-menu item declared in
/// Info.plist (NSMessage = "readSelection"). macOS calls this with the
/// selected text already on `pasteboard` — nothing is read from disk, the
/// network, or any prior session.
final class AppServiceProvider: NSObject {
    private var popup: PopupController?

    @objc func readSelection(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "contextGIST: no text was selected."
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.show(text: text)
        }
    }

    private func show(text: String) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let controller = PopupController(text: text) { [weak self] in
            // Dropping the only reference discards the selection text and
            // its tokenized session — nothing about this reading survives
            // past the window closing.
            self?.popup = nil
        }
        popup = controller
        controller.showWindow()
    }
}
