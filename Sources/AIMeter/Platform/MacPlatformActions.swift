import AppKit

/// macOS platform side-effect boundary injected into `MeterModel` for clean separation & testability.
@MainActor protocol PlatformActions: AnyObject {
    func chooseFile(title: String, initialDirectory: URL?) -> URL?
    func isExecutableFile(atPath path: String) -> Bool
    func isReadableFile(atPath path: String) -> Bool
    func copyToClipboard(_ text: String)
    func loginItemStatus() -> LoginItemStatus
    func setLoginItemEnabled(_ enabled: Bool) throws -> LoginItemStatus
    func observeSystemEvents(
        onWake: @escaping @MainActor () -> Void,
        onAppActive: @escaping @MainActor () -> Void,
        onTerminate: @escaping @MainActor () -> Void
    ) -> [NSObjectProtocol]
    func removeSystemObservers(_ observers: [NSObjectProtocol])
    func terminateApp()
}

@MainActor final class MacPlatformActions: PlatformActions {
    private let launchAgent = LaunchAtLoginAgent()

    func chooseFile(title: String, initialDirectory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = initialDirectory
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func isReadableFile(atPath path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func loginItemStatus() -> LoginItemStatus {
        launchAgent.status()
    }

    func setLoginItemEnabled(_ enabled: Bool) throws -> LoginItemStatus {
        try launchAgent.setEnabled(enabled)
    }

    func observeSystemEvents(
        onWake: @escaping @MainActor () -> Void,
        onAppActive: @escaping @MainActor () -> Void,
        onTerminate: @escaping @MainActor () -> Void
    ) -> [NSObjectProtocol] {
        var tokens: [NSObjectProtocol] = []
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onWake() }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onAppActive() }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onTerminate() }
        })
        return tokens
    }

    func removeSystemObservers(_ observers: [NSObjectProtocol]) {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func terminateApp() {
        NSApp.terminate(nil)
    }
}
