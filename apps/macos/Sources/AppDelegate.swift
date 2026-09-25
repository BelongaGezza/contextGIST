import AppKit

/// contextGIST has no windows, menu bar, or Dock icon until the Services
/// menu fires — see LSUIElement in Info.plist. This delegate's only job is
/// registering the Services provider; everything else happens in
/// `AppServiceProvider` and `PopupController`. Instantiated from main.swift
/// rather than via @NSApplicationMain/@main, so app startup stays a plain,
/// inspectable three lines with no attribute magic.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = AppServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    /// An accessory app with no windows would otherwise sit around
    /// invisibly after the popup closes. Quitting here means macOS just
    /// relaunches it fresh next time the Services item fires — cheap, and
    /// it guarantees no reading session ever lingers in memory.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
