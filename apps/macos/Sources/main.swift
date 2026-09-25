import AppKit

// No @main/@NSApplicationMain — contextGIST needs LSUIElement's zero-window
// startup behavior, which is simplest to reason about as three explicit
// calls rather than relying on lifecycle attribute magic.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
