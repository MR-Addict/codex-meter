import Foundation
import Darwin

/// Shared subprocess configuration and teardown utilities used by one-shot and persistent transports.
enum SubprocessSupport {
    static func augmentedEnvironment(
        forExecutable executable: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = "\(directory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        return environment
    }

    static func configure(_ process: Process, executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = augmentedEnvironment(forExecutable: executable)
    }

    /// Gracefully terminates a running child process with a 1-second `SIGKILL` backstop.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
