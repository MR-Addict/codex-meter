import Foundation

/// Generation-guarded one-shot timer scheduler with injectable test hook.
@MainActor public final class RefreshScheduler {
    public typealias TestHandler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let testHandler: TestHandler?
    private var timer: Timer?
    private var generation = UUID()

    public init(testHandler: TestHandler? = nil) {
        self.testHandler = testHandler
    }

    public func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        let token = UUID()
        generation = token
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == token else { return }
            action()
        }
        if let testHandler {
            testHandler(delay, fire)
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in fire() }
        }
        timer.tolerance = min(2, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
    }
}
