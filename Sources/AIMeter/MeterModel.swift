import SwiftUI
import AppKit
import ServiceManagement
import MeterCore
import Combine

@MainActor final class MeterModel: ObservableObject {
    @Published private(set) var allServices: [DetectedService] = []
    @Published private(set) var disabledServiceIDs: Set<ServiceID> = []
    @Published private(set) var activeServiceID: ServiceID?
    @Published var showingSettings = false
    @Published var expandedSectionIDs: Set<String> = []
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var preferenceError: String?
    @Published private(set) var copiedLoginCommand: String?
    private(set) var isPresentingPanel = false

    let registry: ServiceRegistry
    private let defaults: UserDefaults
    private let testScheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)?
    private var states: [ServiceID: ServiceState] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastAttempt = -Double.infinity
    private var lastResume = -Double.infinity
    private var refreshGeneration = UUID()
    private var timerGeneration = UUID()
    private var stopping = false
    private var popoverIsOpen = false
    private var copiedResetTask: Task<Void, Never>?

    private static let activeServiceDefaultsKey = "activeServiceID"
    private static let disabledServicesDefaultsKey = "disabledServiceIDs"

    var detectedServices: [DetectedService] {
        allServices.filter(\.isDetected)
    }

    var enabledServices: [DetectedService] {
        allServices.filter { $0.isDetected && !disabledServiceIDs.contains($0.id) }
    }

    func isServiceEnabled(_ serviceID: ServiceID) -> Bool {
        !disabledServiceIDs.contains(serviceID)
    }

    var activeDescriptor: ServiceDescriptor? {
        guard let activeServiceID else { return nil }
        return registry.provider(for: activeServiceID)?.descriptor
    }

    var activeState: ServiceState? {
        guard let activeServiceID else { return nil }
        return states[activeServiceID]
    }

    func state(for serviceID: ServiceID) -> ServiceState? {
        states[serviceID]
    }

    func detectionStatus(for serviceID: ServiceID) -> DetectionStatus {
        allServices.first { $0.id == serviceID }?.status ?? .notFound
    }

    func displaySource(for serviceID: ServiceID) -> String? {
        guard let source = detectionStatus(for: serviceID).source else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if source.hasPrefix(home) {
            return "~" + source.dropFirst(home.count)
        }
        return source
    }

    func hasCustomExecutable(for serviceID: ServiceID) -> Bool {
        guard let key = registry.provider(for: serviceID)?.configKeys.executablePathKey else { return false }
        let path = defaults.string(forKey: key) ?? ""
        return !path.isEmpty
    }

    func hasCustomStatusFile(for serviceID: ServiceID) -> Bool {
        guard let key = registry.provider(for: serviceID)?.configKeys.statusFilePathKey else { return false }
        let path = defaults.string(forKey: key) ?? ""
        return !path.isEmpty
    }

    init(
        registry: ServiceRegistry? = nil,
        defaults: UserDefaults = .standard,
        startAutomatically: Bool = true,
        scheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.registry = registry ?? .defaultRegistry()
        self.defaults = defaults
        self.testScheduler = scheduler

        let savedDisabled = defaults.stringArray(forKey: Self.disabledServicesDefaultsKey) ?? []
        self.disabledServiceIDs = Set(savedDisabled.map { ServiceID($0) })

        for provider in self.registry.providers {
            let serviceState = ServiceState(descriptor: provider.descriptor)
            states[provider.descriptor.id] = serviceState
            serviceState.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        performInitialDiscovery()

        if startAutomatically {
            observeEnvironment()
            if activeServiceID != nil {
                refresh()
            }
        }
    }

    // MARK: - Discovery & Switching

    private func performInitialDiscovery() {
        allServices = registry.detectAll()
        let available = enabledServices
        if available.isEmpty {
            activeServiceID = nil
            return
        }
        if let savedRaw = defaults.string(forKey: Self.activeServiceDefaultsKey),
           available.contains(where: { $0.id.rawValue == savedRaw }) {
            activeServiceID = ServiceID(savedRaw)
        } else {
            activeServiceID = available.first?.id
        }
    }

    func rescanServices() {
        guard !stopping else { return }
        let previousActive = activeServiceID
        allServices = registry.detectAll()
        let available = enabledServices

        let nextActive: ServiceID?
        if let previousActive, available.contains(where: { $0.id == previousActive }) {
            nextActive = previousActive
        } else if let savedRaw = defaults.string(forKey: Self.activeServiceDefaultsKey),
                  available.contains(where: { $0.id.rawValue == savedRaw }) {
            nextActive = ServiceID(savedRaw)
        } else {
            nextActive = available.first?.id
        }

        if nextActive != previousActive {
            transitionActiveService(from: previousActive, to: nextActive, persist: false)
        } else if nextActive != nil {
            refresh(force: true)
        }
    }

    func setServiceEnabled(_ serviceID: ServiceID, enabled: Bool) {
        guard !stopping else { return }
        let currentlyEnabled = !disabledServiceIDs.contains(serviceID)
        guard currentlyEnabled != enabled else { return }

        if enabled {
            disabledServiceIDs.remove(serviceID)
        } else {
            disabledServiceIDs.insert(serviceID)
        }
        defaults.set(
            disabledServiceIDs.map(\.rawValue).sorted(),
            forKey: Self.disabledServicesDefaultsKey
        )

        if !enabled {
            if activeServiceID == serviceID {
                let nextActive = enabledServices.first?.id
                transitionActiveService(from: serviceID, to: nextActive, persist: false)
            } else {
                registry.provider(for: serviceID)?.shutdown()
            }
        } else {
            if activeServiceID == nil, enabledServices.contains(where: { $0.id == serviceID }) {
                transitionActiveService(from: nil, to: serviceID, persist: true)
            }
        }
    }

    func toggleSection(_ id: String) {
        if expandedSectionIDs.contains(id) {
            expandedSectionIDs.remove(id)
        } else {
            expandedSectionIDs.insert(id)
        }
    }

    func selectService(_ serviceID: ServiceID) {
        guard !stopping else { return }
        guard serviceID != activeServiceID else { return }
        guard enabledServices.contains(where: { $0.id == serviceID }) else { return }
        transitionActiveService(from: activeServiceID, to: serviceID, persist: true)
    }

    private func transitionActiveService(from oldID: ServiceID?, to newID: ServiceID?, persist: Bool) {
        refreshGeneration = UUID()
        timerGeneration = UUID()
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil

        if let oldID {
            states[oldID]?.cancelRefresh()
            registry.provider(for: oldID)?.shutdown()
        }

        consecutiveFailures = 0
        lastAttempt = -Double.infinity
        copiedLoginCommand = nil
        activeServiceID = newID
        if persist, let newID {
            defaults.set(newID.rawValue, forKey: Self.activeServiceDefaultsKey)
        }

        guard let newID else { return }
        if let state = states[newID],
           state.snapshot != nil,
           state.error == nil,
           let lastSuccess = state.lastSuccess,
           Date().timeIntervalSince(lastSuccess) < 2 {
            scheduleNext(after: RefreshPolicy.delay(
                open: popoverIsOpen,
                lastSuccess: state.lastSuccess,
                retryAt: state.retryAt,
                now: Date()
            ))
        } else {
            refresh(force: true)
        }
    }

    // MARK: - Environment Observation

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.resumeEnvironment()
                    self?.syncLoginStatus()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncLoginStatus() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    // MARK: - Refreshing

    func refresh(force: Bool = false) {
        guard !stopping else { return }
        guard let serviceID = activeServiceID,
              let provider = registry.provider(for: serviceID),
              let state = states[serviceID] else {
            return
        }
        // Ignore accidental duplicate triggers (wake + popover opening together).
        if !force, ProcessInfo.processInfo.systemUptime - lastAttempt < 2 { return }
        guard state.begin() else { return }

        lastAttempt = ProcessInfo.processInfo.systemUptime
        timerGeneration = UUID()
        timer?.invalidate()
        timer = nil

        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            do {
                let snapshot = try await provider.fetchUsage()
                guard let self,
                      !self.stopping,
                      self.refreshGeneration == generation,
                      self.activeServiceID == serviceID else { return }
                self.consecutiveFailures = 0
                state.succeed(snapshot)
                self.scheduleNext(after: self.popoverIsOpen ? RefreshPolicy.openInterval : RefreshPolicy.idleInterval)
            } catch {
                guard let self,
                      !self.stopping,
                      self.refreshGeneration == generation,
                      self.activeServiceID == serviceID else { return }
                self.consecutiveFailures += 1
                let delay = RefreshPolicy.retryDelay(error: error, failures: self.consecutiveFailures)
                state.fail(error, retryAt: Date().addingTimeInterval(delay))
                self.scheduleNext(after: delay)
            }
        }
    }

    private func replaceActiveProvider() {
        guard let serviceID = activeServiceID else { return }
        refreshGeneration = UUID()
        timerGeneration = UUID()
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        registry.provider(for: serviceID)?.resetClient()
        states[serviceID]?.cancelRefresh()
        consecutiveFailures = 0
        refresh(force: true)
    }

    func resumeEnvironment() {
        guard !stopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastResume >= 2 else { return }
        lastResume = now
        allServices = registry.detectAll()
        if let activeServiceID, enabledServices.contains(where: { $0.id == activeServiceID }) {
            // Discard pre-sleep work and its transport; never await its timeout.
            replaceActiveProvider()
        } else {
            rescanServices()
        }
    }

    private func syncLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func scheduleNext(after delay: TimeInterval) {
        guard !stopping, let state = activeState, !state.refreshing else { return }
        timer?.invalidate()
        let generation = UUID()
        timerGeneration = generation
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self, self.timerGeneration == generation, !self.stopping else { return }
            self.refresh(force: true)
        }
        if let testScheduler { testScheduler(delay, fire); return }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in fire() }
        }
        timer.tolerance = min(2, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func popoverDidShow() {
        popoverIsOpen = true
        if activeServiceID == nil {
            rescanServices()
            return
        }
        refresh()
        if let state = activeState, !state.refreshing {
            scheduleNext(after: RefreshPolicy.delay(
                open: true,
                lastSuccess: state.lastSuccess,
                retryAt: state.retryAt,
                now: Date()
            ))
        }
    }

    func popoverDidClose() {
        popoverIsOpen = false
        showingSettings = false
        guard !stopping, let state = activeState, !state.refreshing else { return }
        scheduleNext(after: RefreshPolicy.delay(
            open: false,
            lastSuccess: state.lastSuccess,
            retryAt: state.retryAt,
            now: Date()
        ))
    }

    // MARK: - Preferences & Provider Config

    func chooseExecutable(for serviceID: ServiceID) {
        guard let provider = registry.provider(for: serviceID) else { return }
        let descriptor = provider.descriptor
        let panel = NSOpenPanel()
        panel.title = "Choose \(descriptor.requirementLabel) executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            preferenceError = "Choose an executable file, such as /opt/homebrew/bin/\(descriptor.executableName)."
            return
        }
        defaults.set(url.path, forKey: provider.configKeys.executablePathKey)
        preferenceError = nil
        applyProviderConfigurationChange(for: serviceID)
    }

    func useAutomaticExecutable(for serviceID: ServiceID) {
        guard let provider = registry.provider(for: serviceID) else { return }
        defaults.removeObject(forKey: provider.configKeys.executablePathKey)
        preferenceError = nil
        applyProviderConfigurationChange(for: serviceID)
    }

    func chooseStatusFile(for serviceID: ServiceID) {
        guard let provider = registry.provider(for: serviceID),
              let statusKey = provider.configKeys.statusFilePathKey else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose \(provider.descriptor.name) status JSON file"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli")
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            preferenceError = "Choose a readable JSON file exported by \(provider.descriptor.name)."
            return
        }
        defaults.set(url.path, forKey: statusKey)
        preferenceError = nil
        applyProviderConfigurationChange(for: serviceID)
    }

    func clearStatusFile(for serviceID: ServiceID) {
        guard let provider = registry.provider(for: serviceID),
              let statusKey = provider.configKeys.statusFilePathKey else { return }
        defaults.removeObject(forKey: statusKey)
        preferenceError = nil
        applyProviderConfigurationChange(for: serviceID)
    }

    private func applyProviderConfigurationChange(for serviceID: ServiceID) {
        allServices = registry.detectAll()
        if detectedServices.contains(where: { $0.id == serviceID }) {
            if disabledServiceIDs.contains(serviceID) {
                disabledServiceIDs.remove(serviceID)
                defaults.set(
                    disabledServiceIDs.map(\.rawValue).sorted(),
                    forKey: Self.disabledServicesDefaultsKey
                )
            }
            if activeServiceID == serviceID {
                replaceActiveProvider()
            } else {
                transitionActiveService(from: activeServiceID, to: serviceID, persist: true)
            }
        } else if activeServiceID == serviceID {
            let next = enabledServices.first?.id
            transitionActiveService(from: serviceID, to: next, persist: false)
        }
    }

    func copyLoginCommand(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedLoginCommand = command
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedLoginCommand = nil
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            preferenceError = SMAppService.mainApp.status == .requiresApproval
                ? "Allow AI Meter in System Settings → General → Login Items."
                : nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            preferenceError = "Could not change Launch at Login. Move the app to Applications and try again."
        }
    }

    func stop() {
        stopping = true
        refreshGeneration = UUID()
        timerGeneration = UUID()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
        states.values.forEach {
            $0.clearRetry()
            $0.cancelRefresh()
        }
        timer?.invalidate()
        timer = nil
        copiedResetTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        registry.shutdownAll()
    }
}
