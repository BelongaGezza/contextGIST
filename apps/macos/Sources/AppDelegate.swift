import AppKit

/// contextGIST has no windows, menu bar, or Dock icon until the Services
/// menu fires — see LSUIElement in Info.plist. This delegate's only job is
/// registering the Services provider; everything else happens in
/// `AppServiceProvider` and `PopupController`. Instantiated from main.swift
/// rather than via @NSApplicationMain/@main, so app startup stays a plain,
/// inspectable three lines with no attribute magic.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = AppServiceProvider()

    /// How long a launch may sit without receiving a selection before the
    /// app quits. A Services launch delivers its text well within this; a
    /// plain launch (e.g. the "launch once" step in docs/MACOS_GUIDE.md)
    /// has nothing to do and shouldn't linger invisibly.
    private static let idleLaunchTimeout: TimeInterval = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLaunchTimeout) { [serviceProvider] in
            serviceProvider.quitIfIdle()
        }
    }

    /// An accessory app with no windows would otherwise sit around
    /// invisibly after the popup closes. Quitting means macOS just
    /// relaunches it fresh next time the Services item fires — cheap, and
    /// no reading session lingers in memory. Backstop only: the primary
    /// path is `AppServiceProvider.quitIfIdle()`, which also covers cases
    /// where no window was ever opened.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
