import SwiftUI
import AppKit
import ServiceManagement
import MeterCore
import Combine

@MainActor final class MeterModel: ObservableObject {
    let state = UsageState()
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var preferenceError: String?
    private var client: RPCClient?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var stopping = false
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        refresh()
    }
    func refresh() {
        guard !stopping, state.begin() else { return }
        objectWillChange.send()
        if client == nil {
            client = RPCClient {
                guard let executable = CLILocator.locate(custom: UserDefaults.standard.string(forKey: "codexPath")) else { throw MeterError.missingCLI }
                return ProcessTransport(executable: executable)
            }
        }
        refreshTask = Task {
            do {
                let usage = try await client!.readUsage()
                guard !stopping else { return }
                state.succeed(usage)
            } catch {
                guard !stopping else { return }
                state.fail(error)
            }
            objectWillChange.send()
        }
    }
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
        refresh()
    }
    func useAutomaticCLI() {
        UserDefaults.standard.removeObject(forKey: "codexPath")
        client?.shutdown(); client = nil
        refresh()
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

@MainActor final class StatusController: NSObject {
    private let model = MeterModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscription: AnyCancellable?

    override init() {
        super.init()
        popover.behavior = .transient
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
        update()
        subscription = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        let percentage = model.state.usage?.remaining.map { "\($0)%" } ?? "—"
        item.button?.title = " " + percentage + (model.state.error != nil ? " ·" : "")
        item.button?.toolTip = model.state.error ?? "Codex: \(percentage) remaining"
    }
    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    func stop() { model.stop() }

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

struct MeterView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Usage").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Remaining").font(.system(size: 11)).foregroundStyle(.secondary)
                }

                if let usage = model.state.usage {
                    if let core = usage.core {
                        Text("Codex").font(.system(size: 12, weight: .semibold))
                        bucket(core, now: context.date)
                    } else {
                        Text("Usage unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                    if let count = usage.rateLimitResetCredits?.availableCount {
                        detail("Earned resets", value: "\(count)")
                    }
                    ForEach(usage.additionalBuckets, id: \.0) { key, value in
                        Divider()
                        Text(value.limitName ?? key)
                            .font(.system(size: 12, weight: .semibold))
                        bucket(value, now: context.date)
                    }
                } else if model.state.error == nil {
                    Text("Loading usage…").font(.caption).foregroundStyle(.secondary)
                }

                if let error = model.state.error {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.state.usage != nil {
                            Label("Usage may be out of date", systemImage: "exclamationmark.triangle")
                                .font(.caption.weight(.medium))
                        }
                        Text(error).font(.caption).textSelection(.enabled)
                    }.foregroundStyle(.orange)
                }
                if let error = model.preferenceError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                Divider()
                HStack(spacing: 14) {
                    if let last = model.state.lastSuccess {
                        Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button(action: model.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(model.state.refreshing ? .tertiary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.state.refreshing)
                    .help(model.state.refreshing ? "Refreshing…" : "Refresh usage")
                    .accessibilityLabel("Refresh usage")

                    Menu {
                        Toggle("Launch at Login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                        Menu("Codex CLI") {
                            Button("Choose Executable…", action: model.chooseCLI)
                            Button("Detect Automatically", action: model.useAutomaticCLI)
                            Divider()
                            Link("Installation and Sign-in Guide", destination: URL(string: "https://developers.openai.com/codex/cli")!)
                        }.disabled(model.state.refreshing)
                        Divider()
                        Button("Quit Codex Meter") { model.stop(); NSApp.terminate(nil) }
                            .keyboardShortcut("q")
                    } label: {
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Settings")
                    .accessibilityLabel("Settings")
                }.font(.system(size: 12))
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private func detail(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 11))
    }

    @ViewBuilder private func bucket(_ value: Bucket, now: Date) -> some View {
        ForEach(Array(value.windows.enumerated()), id: \.offset) { _, window in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(window.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.remaining)%")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(window.remaining <= 10 ? Color.orange : Color.primary)
            }
            .help(window.resetText(now: now))
            .accessibilityValue("\(window.remaining)% remaining. \(window.resetText(now: now))")
        }
        if value.windows.isEmpty {
            Text("Allowance unavailable").font(.caption).foregroundStyle(.secondary)
        }
        if let credits = value.credits { detail("Credits", value: credits.display) }
    }
}
