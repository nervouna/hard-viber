import Foundation

/// The user's optional settings in `~/Library/Application Support/Quota/config.json`. The collector
/// reads the provider settings from the same file and reports problems with it; the app only needs
/// `node`, and falls back to the defaults when the file is missing or broken.
struct UserConfig: Decodable {
    var node: String?

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quota/config.json")

    static func load(from url: URL = url) -> UserConfig {
        guard let data = try? Data(contentsOf: url) else { return UserConfig() }
        return (try? JSONDecoder().decode(UserConfig.self, from: data)) ?? UserConfig()
    }
}

/// Finds the Node that runs the collector. An app launched from Finder has a minimal PATH, so the
/// usual install directories are searched before it.
enum NodeLocator {
    /// A configured path is the only candidate. Otherwise Homebrew's node@24 comes first, then any
    /// `node` in the directories the collector searches for tools, then in PATH.
    static func candidates(configured: String?, path: String?, home: String) -> [String] {
        if let configured, !configured.isEmpty {
            return [configured == "~" ? home : configured.hasPrefix("~/") ? home + configured.dropFirst() : configured]
        }
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
            + (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let all = ["/opt/homebrew/opt/node@24/bin/node", "/usr/local/opt/node@24/bin/node"] + directories.map { "\($0)/node" }
        return all.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func locate(configured: String?, path: String? = ProcessInfo.processInfo.environment["PATH"],
                       home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                       isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Result<String, CollectorFailure> {
        let candidates = candidates(configured: configured, path: path, home: home)
        if let node = candidates.first(where: isExecutable) { return .success(node) }
        let checked = candidates.map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        return .failure(CollectorFailure(configured?.isEmpty == false
            ? "Collector spawn: \(checked[0]) is not installed (set in config.json)"
            : "Collector spawn: Node.js is not installed (checked \(checked.joined(separator: ", ")))"))
    }
}
