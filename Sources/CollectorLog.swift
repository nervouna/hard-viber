import Foundation

/// The collector's diagnostics log. The collector writes its stderr here and the app
/// appends its own failures, so one file explains every failed refresh.
enum CollectorLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Quota/collector.log")
    static let limit = 256 * 1024

    /// Opens the log for appending. A log past the limit first moves to `collector.log.1`,
    /// which keeps both files bounded. O_APPEND lets the app and the collector share it.
    static func handle(at url: URL = url, limit: Int = limit) -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
            let previous = url.appendingPathExtension("1")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func append(_ message: String, at url: URL = url, limit: Int = limit) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? handle(at: url, limit: limit)?.write(contentsOf: Data(line.utf8))
    }
}
