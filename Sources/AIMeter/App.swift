import SwiftUI
import AppKit
import MeterCore
import Combine

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
    private var iconCache: [ServiceIconKind: NSImage] = [:]

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let content = NSHostingController(rootView: MeterView(model: model))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("AI Meter usage")
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
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
        guard let button = item.button else { return }

        guard let descriptor = model.activeDescriptor, let state = model.activeState else {
            button.image = icon(for: .generic)
            button.title = " —"
            button.setAccessibilityLabel("AI Meter: no supported services detected")
            button.toolTip = "AI Meter — No supported AI tools detected.\nClick to locate a CLI or rescan."
            return
        }

        let percentage = state.menuBarValue
        button.image = icon(for: descriptor.iconKind)
        button.title = " " + percentage + (state.isStale ? " ·" : "")
        button.setAccessibilityLabel("\(descriptor.name) usage: \(percentage)")

        let switchHint = model.detectedServices.count > 1 ? "\nClick to view details or switch services." : ""
        if let error = state.error, state.snapshot != nil {
            button.toolTip = "\(descriptor.name): \(percentage) remaining, showing last known usage.\n\(error)"
        } else if let reset = state.snapshot?.resetSummary() {
            button.toolTip = "\(descriptor.name): \(percentage) remaining\n\(reset)\(switchHint)"
        } else if let error = state.error {
            button.toolTip = "\(descriptor.name) usage unavailable.\n\(error)"
        } else if state.snapshot != nil {
            button.toolTip = "\(descriptor.name): \(percentage) remaining\(switchHint)"
        } else {
            button.toolTip = state.refreshing ? "\(descriptor.name): connecting…" : "\(descriptor.name) usage"
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

    private func installEventMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            Task { @MainActor in self?.closeForOutsideClick() }
        }) {
            monitors.append(global)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            var handled = false
            MainActor.assumeIsolated {
                guard let self, PanelDismissalPolicy.escape(
                    isShown: self.popover.isShown,
                    isPanelWindow: event.window != nil && event.window === self.popover.contentViewController?.view.window
                ) else { return }
                if self.model.showingSettings {
                    self.model.showingSettings = false
                } else {
                    self.popover.performClose(nil)
                }
                handled = true
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    private func closeForOutsideClick() {
        guard PanelDismissalPolicy.outsideClick(
            isShown: popover.isShown,
            isPresentingPanel: model.isPresentingPanel
        ) else { return }
        popover.performClose(nil)
    }

    private func removeEventMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) { model.popoverDidShow() }
    func popoverDidClose(_ notification: Notification) { model.popoverDidClose() }

    // MARK: - Template Menu Bar Icons

    private func icon(for kind: ServiceIconKind) -> NSImage {
        if let cached = iconCache[kind] { return cached }
        let created = ServiceMenuBarIcon.makeTemplateImage(for: kind)
        iconCache[kind] = created
        return created
    }
}
