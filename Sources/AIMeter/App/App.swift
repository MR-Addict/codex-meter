import AppKit

@main enum AIMeterApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MeterAppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        // Keep the delegate alive for the event loop without creating any window scene.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class MeterAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}
