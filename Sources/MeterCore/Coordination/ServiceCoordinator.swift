import Foundation
import Combine

/// Pure, AppKit-free coordinator managing multi-service discovery, active selection,
/// per-service state caching, refresh cadence, retry backoff, and provider configuration.
@MainActor public final class ServiceCoordinator: ObservableObject {
    @Published public private(set) var allServices: [DetectedService] = []
    @Published public private(set) var disabledServiceIDs: Set<ServiceID> = []
    @Published public private(set) var activeServiceID: ServiceID?

    public let registry: ServiceRegistry
    public let configStore: any ProviderConfigStore

    private let scheduler: RefreshScheduler
    private var states: [ServiceID: ServiceState] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastAttempt = -Double.infinity
    private var lastResume = -Double.infinity
    private var refreshGeneration = UUID()
    private var stopping = false
    private var popoverIsOpen = false

    public static let activeServiceDefaultsKey = "activeServiceID"
    public static let disabledServicesDefaultsKey = "disabledServiceIDs"

    public init(
        registry: ServiceRegistry? = nil,
        configStore: any ProviderConfigStore = UserDefaultsConfigStore(),
        startAutomatically: Bool = true,
        scheduler: RefreshScheduler.TestHandler? = nil
    ) {
        self.configStore = configStore
        self.registry = registry ?? .defaultRegistry(configStore: configStore)
        self.scheduler = RefreshScheduler(testHandler: scheduler)

        let savedDisabled = configStore.stringArray(forKey: Self.disabledServicesDefaultsKey) ?? []
        self.disabledServiceIDs = Set(savedDisabled.map { ServiceID($0) })

        for provider in self.registry.providers {
            let serviceState = ServiceState(descriptor: provider.descriptor)
            states[provider.descriptor.id] = serviceState
            serviceState.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        performInitialDiscovery()

        if startAutomatically, activeServiceID != nil {
            refresh()
        }
    }

    // MARK: - Derived State

    public var detectedServices: [DetectedService] {
        allServices.filter(\.isDetected)
    }

    public var enabledServices: [DetectedService] {
        allServices.filter { $0.isDetected && !disabledServiceIDs.contains($0.id) }
    }

    public func isServiceEnabled(_ serviceID: ServiceID) -> Bool {
        !disabledServiceIDs.contains(serviceID)
    }

    public var activeDescriptor: ServiceDescriptor? {
        guard let activeServiceID else { return nil }
        return registry.provider(for: activeServiceID)?.descriptor
    }

    public var activeState: ServiceState? {
        guard let activeServiceID else { return nil }
        return states[activeServiceID]
    }

    public func state(for serviceID: ServiceID) -> ServiceState? {
        states[serviceID]
    }

    public func configSpec(for serviceID: ServiceID) -> ProviderConfigSpec? {
        registry.provider(for: serviceID)?.configSpec
    }

    public func detectionStatus(for serviceID: ServiceID) -> DetectionStatus {
        allServices.first { $0.id == serviceID }?.status ?? .notFound
    }

    public func displaySource(for serviceID: ServiceID) -> String? {
        guard let source = detectionStatus(for: serviceID).source else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if source.hasPrefix(home) {
            return "~" + source.dropFirst(home.count)
        }
        return source
    }

    public func hasCustomExecutable(for serviceID: ServiceID) -> Bool {
        guard let key = configSpec(for: serviceID)?.executablePathKey else { return false }
        let path = configStore.string(forKey: key) ?? ""
        return !path.isEmpty
    }

    public func hasCustomSupplementalFile(for serviceID: ServiceID) -> Bool {
        guard let key = configSpec(for: serviceID)?.supplementalFile?.defaultsKey else { return false }
        let path = configStore.string(forKey: key) ?? ""
        return !path.isEmpty
    }

    // MARK: - Discovery & Switching

    private func performInitialDiscovery() {
        allServices = registry.detectAll()
        let available = enabledServices
        if available.isEmpty {
            activeServiceID = nil
            return
        }
        if let savedRaw = configStore.string(forKey: Self.activeServiceDefaultsKey),
           available.contains(where: { $0.id.rawValue == savedRaw }) {
            activeServiceID = ServiceID(savedRaw)
        } else {
            activeServiceID = available.first?.id
        }
    }

    public func rescanServices() {
        guard !stopping else { return }
        let previousActive = activeServiceID
        allServices = registry.detectAll()
        let available = enabledServices

        let nextActive: ServiceID?
        if let previousActive, available.contains(where: { $0.id == previousActive }) {
            nextActive = previousActive
        } else if let savedRaw = configStore.string(forKey: Self.activeServiceDefaultsKey),
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

    public func setServiceEnabled(_ serviceID: ServiceID, enabled: Bool) {
        guard !stopping else { return }
        let currentlyEnabled = !disabledServiceIDs.contains(serviceID)
        guard currentlyEnabled != enabled else { return }

        if enabled {
            disabledServiceIDs.remove(serviceID)
        } else {
            disabledServiceIDs.insert(serviceID)
        }
        configStore.setStringArray(
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
        } else if activeServiceID == nil, enabledServices.contains(where: { $0.id == serviceID }) {
            transitionActiveService(from: nil, to: serviceID, persist: true)
        }
    }

    public func selectService(_ serviceID: ServiceID) {
        guard !stopping else { return }
        guard serviceID != activeServiceID else { return }
        guard enabledServices.contains(where: { $0.id == serviceID }) else { return }
        transitionActiveService(from: activeServiceID, to: serviceID, persist: true)
    }

    private func transitionActiveService(from oldID: ServiceID?, to newID: ServiceID?, persist: Bool) {
        refreshGeneration = UUID()
        scheduler.cancel()
        refreshTask?.cancel()
        refreshTask = nil

        if let oldID {
            states[oldID]?.cancelRefresh()
            registry.provider(for: oldID)?.shutdown()
        }

        consecutiveFailures = 0
        lastAttempt = -Double.infinity
        activeServiceID = newID
        if persist, let newID {
            configStore.setString(newID.rawValue, forKey: Self.activeServiceDefaultsKey)
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

    // MARK: - Refreshing & Lifecycle

    public func refresh(force: Bool = false) {
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
        scheduler.cancel()

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

    public func resumeEnvironment() {
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

    public func popoverDidShow() {
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

    public func popoverDidClose() {
        popoverIsOpen = false
        guard !stopping, let state = activeState, !state.refreshing else { return }
        scheduleNext(after: RefreshPolicy.delay(
            open: false,
            lastSuccess: state.lastSuccess,
            retryAt: state.retryAt,
            now: Date()
        ))
    }

    // MARK: - Provider Configuration Mutations

    public func setCustomExecutablePath(_ path: String?, for serviceID: ServiceID) {
        guard let key = configSpec(for: serviceID)?.executablePathKey else { return }
        configStore.setString(path, forKey: key)
        applyProviderConfigurationChange(for: serviceID)
    }

    public func setSupplementalFilePath(_ path: String?, for serviceID: ServiceID) {
        guard let key = configSpec(for: serviceID)?.supplementalFile?.defaultsKey else { return }
        configStore.setString(path, forKey: key)
        applyProviderConfigurationChange(for: serviceID)
    }

    public func stop() {
        stopping = true
        refreshGeneration = UUID()
        scheduler.cancel()
        states.values.forEach {
            $0.clearRetry()
            $0.cancelRefresh()
        }
        refreshTask?.cancel()
        refreshTask = nil
        registry.shutdownAll()
    }

    // MARK: - Internal Helpers

    private func replaceActiveProvider() {
        guard let serviceID = activeServiceID else { return }
        refreshGeneration = UUID()
        scheduler.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        registry.provider(for: serviceID)?.resetClient()
        states[serviceID]?.cancelRefresh()
        consecutiveFailures = 0
        refresh(force: true)
    }

    private func applyProviderConfigurationChange(for serviceID: ServiceID) {
        allServices = registry.detectAll()
        if detectedServices.contains(where: { $0.id == serviceID }) {
            if disabledServiceIDs.contains(serviceID) {
                disabledServiceIDs.remove(serviceID)
                configStore.setStringArray(
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

    private func scheduleNext(after delay: TimeInterval) {
        guard !stopping, let state = activeState, !state.refreshing else { return }
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, !self.stopping else { return }
            self.refresh(force: true)
        }
    }
}
