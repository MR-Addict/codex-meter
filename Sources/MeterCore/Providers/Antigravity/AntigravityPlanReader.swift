import Darwin
import Foundation

/// The CLI supplies plan_tier to interactive status-line commands, including before the first prompt.
enum AntigravityPlanReader {
    static func read(executable: String) async throws -> String? {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let planFile = directory.appendingPathComponent("tier")
        // Extract only the tier. Publish it atomically so a poll cannot see a partial write.
        let command = #"/usr/bin/plutil -extract plan_tier raw -expect string -o "$AI_METER_TIER.partial" - && /bin/mv -f "$AI_METER_TIER.partial" "$AI_METER_TIER""#
        let settings = ["statusLine": ["type": "command", "enabled": true, "command": command]]
        let json = try JSONSerialization.data(withJSONObject: settings)

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { close(master) }
        guard fcntl(master, F_SETFL, O_NONBLOCK) == 0,
              fcntl(master, F_SETFD, FD_CLOEXEC) == 0 else { return nil }

        let process = Process()
        SubprocessSupport.configure(process, executable: executable,
                                    arguments: ["--settings", String(decoding: json, as: UTF8.self)])
        process.environment?["AI_METER_TIER"] = planFile.path
        process.environment?["TERM"] = "xterm-256color"
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
        defer { SubprocessSupport.terminate(process) }

        let deadline = ContinuousClock.now + .seconds(12)
        var buffer = [UInt8](repeating: 0, count: 16384)
        repeat {
            try Task.checkCancellation()
            if let tier = try? String(contentsOf: planFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty {
                return tier
            }
            // Discard terminal rendering so it cannot block status-line updates.
            _ = Darwin.read(master, &buffer, buffer.count)
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return nil
    }
}
