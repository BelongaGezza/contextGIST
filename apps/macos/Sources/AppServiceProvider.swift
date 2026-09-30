import AppKit

/// Handles the "Speed Read with contextGIST" Services-menu item declared in
/// Info.plist (NSMessage = "readSelection"). macOS calls this with the
/// selected text already on `pasteboard` — nothing is read from disk, the
/// network, or any prior session.
final class AppServiceProvider: NSObject {
    /// Largest selection accepted, in UTF-8 bytes: about 85,000 words, or
    /// ~5.8 hours at the default 250 WPM. Far beyond any real speed-reading
    /// session, but it bounds the memory and tokenizing time a misbehaving
    /// Services-sending app can impose (docs/SECURITY_REVIEW.md finding #1).
    /// Without it, the only ceiling was gist-model's 256 MB `ParseLimits`.
    static let maxSelectionBytes = 512 * 1024

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
        guard !Self.exceedsCap(text) else {
            DispatchQueue.main.async { Self.showTooLongAlert() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.show(text: text)
        }
    }

    /// UTF-8 is never shorter than UTF-16 in code units, so the O(1)
    /// `NSString.length` (UTF-16) rejects huge pasteboard strings without
    /// walking them. Only strings that pass that are measured in UTF-8,
    /// which is O(n) for a bridged `NSString`.
    static func exceedsCap(_ text: String) -> Bool {
        if (text as NSString).length > maxSelectionBytes { return true }
        return text.utf8.count > maxSelectionBytes
    }

    private static func showTooLongAlert() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let limit = ByteCountFormatter.string(
            fromByteCount: Int64(maxSelectionBytes), countStyle: .binary
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Selection too long to speed-read"
        alert.informativeText = "contextGIST reads selections up to \(limit) of text (about 85,000 words). Select a shorter passage and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
