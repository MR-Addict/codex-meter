import SwiftUI
import AppKit
import ServiceManagement
import MeterCore
import Combine

@MainActor final class MeterModel: ObservableObject {
    let state = UsageState()
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var preferenceError: String?
    @Published var closeOnOutsideClick: Bool {
        didSet { UserDefaults.standard.set(closeOnOutsideClick, forKey: "closeOnOutsideClick") }
    }
    /// When the current fetch failed, the moment the automatic retry is scheduled.
    @Published private(set) var retryAt: Date?
    @Published private(set) var loginCommandCopied = false

    private var client: RPCClient?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastAttempt = Date.distantPast
    private var stopping = false
    private var popoverIsOpen = false
    private var copiedResetTask: Task<Void, Never>?

    /// Background cadence once a refresh has succeeded. Kept short so the menu
    /// bar figure stays close to the value shown in Codex itself.
    private let idleInterval: TimeInterval = 60
    /// Faster cadence while the popover is open, so the panel feels live.
    private let openInterval: TimeInterval = 20

    init() {
        closeOnOutsideClick = UserDefaults.standard.object(forKey: "closeOnOutsideClick") as? Bool ?? true
        // UsageState owns the snapshot; forward its changes so SwiftUI observes
        // the model as a single object.
        state.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        observeEnvironment()
        refresh()
    }

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    // MARK: - Refreshing

    func refresh(force: Bool = false) {
        guard !stopping else { return }
        // Ignore accidental duplicate triggers (wake + popover opening together).
        if !force, Date().timeIntervalSince(lastAttempt) < 2 { return }
        guard state.begin() else { return }
        lastAttempt = Date()
        retryAt = nil
        timer?.invalidate()
        timer = nil

        if client == nil {
            client = RPCClient {
                guard let executable = CLILocator.locate(custom: UserDefaults.standard.string(forKey: "codexPath")) else { throw MeterError.missingCLI }
                return ProcessTransport(executable: executable)
            }
        }
        let client = client!
        refreshTask = Task { [weak self] in
            do {
                let usage = try await client.readUsage()
                guard let self, !self.stopping else { return }
                self.consecutiveFailures = 0
                self.state.succeed(usage)
                self.scheduleNext(after: self.popoverIsOpen ? self.openInterval : self.idleInterval)
            } catch {
                guard let self, !self.stopping else { return }
                self.consecutiveFailures += 1
                self.state.fail(error)
                let delay = self.retryDelay(for: error)
                self.retryAt = Date().addingTimeInterval(delay)
                self.scheduleNext(after: delay)
            }
        }
    }

    private func retryDelay(for error: Error) -> TimeInterval {
        switch error as? MeterError {
        case .missingCLI:
            // The CLI is not installed yet; check occasionally so a fresh
            // install is picked up without a manual refresh.
            return 60
        case .login, .unsupported:
            return 120
        default:
            // 5s, 10s, 20s, 40s … capped at one minute.
            return min(60, 5 * pow(2, Double(max(0, consecutiveFailures - 1))))
        }
    }

    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(2, delay * 0.1)
        // `.common` keeps the timer alive while the popover or a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func popoverDidShow() {
        popoverIsOpen = true
        refresh(force: true)
    }

    func popoverDidClose() {
        popoverIsOpen = false
        if state.error == nil {
            scheduleNext(after: idleInterval)
        }
    }

    // MARK: - Preferences

    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex CLI executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            preferenceError = "Choose an executable file, such as /opt/homebrew/bin/codex."
            return
        }
        UserDefaults.standard.set(url.path, forKey: "codexPath")
        preferenceError = nil
        client?.shutdown(); client = nil
        refresh(force: true)
    }

    func useAutomaticCLI() {
        UserDefaults.standard.removeObject(forKey: "codexPath")
        client?.shutdown(); client = nil
        refresh(force: true)
    }

    func copyLoginCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("codex login", forType: .string)
        loginCommandCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.loginCommandCopied = false
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            preferenceError = SMAppService.mainApp.status == .requiresApproval ? "Allow Codex Meter in System Settings → General → Login Items." : nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            preferenceError = "Could not change Launch at Login. Move the app to Applications and try again."
        }
    }

    func stop() {
        stopping = true
        timer?.invalidate()
        timer = nil
        copiedResetTask?.cancel()
        refreshTask?.cancel()
        client?.shutdown()
    }
}

@main enum CodexMeterApp {
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
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}

@MainActor final class StatusController: NSObject, NSPopoverDelegate {
    private let model = MeterModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscription: AnyCancellable?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let content = NSHostingController(rootView: MeterView(model: model))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        if let button = item.button {
            button.image = Self.makeIcon()
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Codex usage")
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.closeForOutsideClick() }
        })
        installEventMonitors()
        update()
        subscription = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    // MARK: - Menu bar

    private func update() {
        let state = model.state
        let percentage = state.usage?.remaining.map { "\($0)%" } ?? "—"
        let stale = state.error != nil && state.usage != nil
        item.button?.title = " " + percentage + (stale ? " ·" : "")

        if let error = state.error, state.usage != nil {
            item.button?.toolTip = "Codex: \(percentage) remaining, showing last known usage.\n\(error)"
        } else if let reset = state.usage?.resetSummary() {
            item.button?.toolTip = "Codex: \(percentage) remaining\n\(reset)"
        } else if let error = state.error {
            item.button?.toolTip = "Codex usage unavailable.\n\(error)"
        } else {
            item.button?.toolTip = state.refreshing ? "Codex: connecting…" : "Codex usage"
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func stop() {
        removeEventMonitors()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        model.stop()
    }

    // MARK: - Popover dismissal
    //
    // `NSPopover.behavior = .transient` relies on window-server heuristics that
    // behave differently across Macs and input devices. Dismiss explicitly on
    // outside clicks / app deactivation/escape so every Mac behaves the same.

    private func installEventMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Only global events are observed for the mouse: clicks inside the
        // popover (including its menus) belong to this app and must be left
        // alone. Clicks anywhere else land in another app or the Finder.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            Task { @MainActor in self?.closeForOutsideClick() }
        }) {
            monitors.append(global)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown,
                      event.window === self.popover.contentViewController?.view.window else { return }
                self.popover.performClose(nil)
                handled = true
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    private func closeForOutsideClick() {
        guard popover.isShown, model.closeOnOutsideClick else { return }
        popover.performClose(nil)
    }

    private func removeEventMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) { model.popoverDidShow() }
    func popoverDidClose(_ notification: Notification) { model.popoverDidClose() }

    // A drawn template image stays visible independently of SwiftUI text rendering.
    private static func makeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 15, height: 13), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.4
            frame.stroke()
            let mark = NSBezierPath()
            mark.lineWidth = 1.5
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.move(to: NSPoint(x: 5, y: 11.5))
            mark.line(to: NSPoint(x: 7.5, y: 9))
            mark.line(to: NSPoint(x: 5, y: 6.5))
            mark.move(to: NSPoint(x: 10, y: 6.5))
            mark.line(to: NSPoint(x: 13, y: 6.5))
            mark.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
