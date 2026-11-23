import Foundation

/// Locates CLI executables across custom overrides, standard macOS paths, and `$PATH`.
public enum ExecutableLocator {
    public static func locate(
        name: String,
        custom: String? = nil,
        extraCandidates: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let custom, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return isExecutable(expanded) ? expanded : nil
        }

        var candidates: [String] = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(homeDirectory)/.local/bin/\(name)",
            "\(homeDirectory)/.npm-global/bin/\(name)",
        ]
        candidates.append(contentsOf: extraCandidates.map { ($0 as NSString).expandingTildeInPath })
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }
}
