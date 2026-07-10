import AppKit
import SwiftUI

@main
struct PlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("ActionRouter Playground") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

/// Running a SwiftUI app from a SwiftPM executable (no .app bundle) needs
/// an explicit activation policy, otherwise the window opens behind other
/// apps without a Dock presence.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
