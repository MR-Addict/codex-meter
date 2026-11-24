import SwiftUI
import MeterCore
import Combine

/// Thin macOS presentation ViewModel composing `ServiceCoordinator` (domain orchestration)
/// with `PlatformActions` (AppKit / ServiceManagement side effects) and ephemeral UI state.
@MainActor final class MeterModel: ObservableObject {
    @Published var showingSettings = false
    @Published var toggledSectionIDs: Set<String> = []
    @Published var loginEnabled: Bool
    @Published var preferenceError: String?
    @Published private(set) var copiedLoginCommand: String?
    private(set) var isPresentingPanel = false

    let coordinator: ServiceCoordinator
    private let platform: any PlatformActions
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var copiedResetTask: Task<Void, Never>?

    init(
        coordinator: ServiceCoordinator? = nil,
        registry: ServiceRegistry? = nil,
        configStore: any ProviderConfigStore = UserDefaultsConfigStore(),
        platform: (any PlatformActions)? = nil,
        startAutomatically: Bool = true,
        scheduler: RefreshScheduler.TestHandler? = nil
    ) {
        let resolvedPlatform = platform ?? MacPlatformActions()
        self.platform = resolvedPlatform
        self.loginEnabled = resolvedPlatform.loginItemStatus() == .enabled
        self.coordinator = coordinator ?? ServiceCoordinator(
            registry: registry,
            configStore: configStore,
            startAutomatically: startAutomatically,
            scheduler: scheduler
        )

        self.coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        self.coordinator.$activeServiceID
            .dropFirst()
            .sink { [weak self] _ in self?.copiedLoginCommand = nil }
            .store(in: &cancellables)

        if startAutomatically {
            observers = resolvedPlatform.observeSystemEvents(
                onWake: { [weak self] in
                    self?.coordinator.resumeEnvironment()
                    self?.syncLoginStatus()
                },
                onAppActive: { [weak self] in
                    self?.syncLoginStatus()
                },
                onTerminate: { [weak self] in
                    self?.stop()
                }
            )
        }
    }

    // MARK: - Forwarded Service State

    var allServices: [DetectedService] { coordinator.allServices }
    var detectedServices: [DetectedService] { coordinator.detectedServices }
    var enabledServices: [DetectedService] { coordinator.enabledServices }
    var activeServiceID: ServiceID? { coordinator.activeServiceID }
    var activeDescriptor: ServiceDescriptor? { coordinator.activeDescriptor }
    var activeState: ServiceState? { coordinator.activeState }

    func isServiceEnabled(_ serviceID: ServiceID) -> Bool {
        coordinator.isServiceEnabled(serviceID)
    }

    func state(for serviceID: ServiceID) -> ServiceState? {
        coordinator.state(for: serviceID)
    }

    func configSpec(for serviceID: ServiceID) -> ProviderConfigSpec? {
        coordinator.configSpec(for: serviceID)
    }

    func displaySource(for serviceID: ServiceID) -> String? {
        coordinator.displaySource(for: serviceID)
    }

    func hasCustomExecutable(for serviceID: ServiceID) -> Bool {
        coordinator.hasCustomExecutable(for: serviceID)
    }

    func hasCustomSupplementalFile(for serviceID: ServiceID) -> Bool {
        coordinator.hasCustomSupplementalFile(for: serviceID)
    }

    // MARK: - Service & Lifecycle Actions

    func rescanServices() { coordinator.rescanServices() }
    func selectService(_ serviceID: ServiceID) { coordinator.selectService(serviceID) }
    func setServiceEnabled(_ serviceID: ServiceID, enabled: Bool) {
        coordinator.setServiceEnabled(serviceID, enabled: enabled)
    }
    func refresh(force: Bool = false) { coordinator.refresh(force: force) }
    func resumeEnvironment() { coordinator.resumeEnvironment() }
    func popoverDidShow() { coordinator.popoverDidShow() }
    func popoverDidClose() {
        showingSettings = false
        coordinator.popoverDidClose()
    }

    // MARK: - Collapsible Section UI State

    func isSectionExpanded(_ section: QuotaSection) -> Bool {
        section.isExpandedByDefault != toggledSectionIDs.contains(section.id)
    }

    func toggleSection(_ id: String) {
        if toggledSectionIDs.contains(id) {
            toggledSectionIDs.remove(id)
        } else {
            toggledSectionIDs.insert(id)
        }
    }

    // MARK: - Preferences & Platform Actions

    func chooseExecutable(for serviceID: ServiceID) {
        guard let provider = coordinator.registry.provider(for: serviceID) else { return }
        let descriptor = provider.descriptor
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        guard let url = platform.chooseFile(
            title: "Choose \(descriptor.requirementLabel) executable",
            initialDirectory: URL(fileURLWithPath: "/opt/homebrew/bin")
        ) else { return }

        guard platform.isExecutableFile(atPath: url.path) else {
            preferenceError = "Choose an executable file, such as /opt/homebrew/bin/\(descriptor.executableName)."
            return
        }
        preferenceError = nil
        coordinator.setCustomExecutablePath(url.path, for: serviceID)
    }

    func useAutomaticExecutable(for serviceID: ServiceID) {
        preferenceError = nil
        coordinator.setCustomExecutablePath(nil, for: serviceID)
    }

    func chooseSupplementalFile(for serviceID: ServiceID) {
        guard let spec = coordinator.configSpec(for: serviceID)?.supplementalFile else { return }
        let initialDir = spec.defaultRelativeDirectory.map {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0)
        }
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        guard let url = platform.chooseFile(
            title: spec.panelTitle,
            initialDirectory: initialDir
        ) else { return }

        guard platform.isReadableFile(atPath: url.path) else {
            preferenceError = spec.unreadableErrorMessage
            return
        }
        preferenceError = nil
        coordinator.setSupplementalFilePath(url.path, for: serviceID)
    }

    func clearSupplementalFile(for serviceID: ServiceID) {
        preferenceError = nil
        coordinator.setSupplementalFilePath(nil, for: serviceID)
    }

    func copyLoginCommand(_ command: String) {
        platform.copyToClipboard(command)
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
            let status = try platform.setLoginItemEnabled(enabled)
            loginEnabled = status == .enabled
            preferenceError = status == .requiresApproval
                ? "Allow AI Meter in System Settings → General → Login Items."
                : nil
        } catch {
            loginEnabled = platform.loginItemStatus() == .enabled
            preferenceError = "Could not update Launch at Login. Check permissions for ~/Library/LaunchAgents."
        }
    }

    func quit() {
        stop()
        platform.terminateApp()
    }

    func stop() {
        platform.removeSystemObservers(observers)
        observers.removeAll()
        copiedResetTask?.cancel()
        copiedResetTask = nil
        coordinator.stop()
    }

    private func syncLoginStatus() {
        loginEnabled = platform.loginItemStatus() == .enabled
    }
}
