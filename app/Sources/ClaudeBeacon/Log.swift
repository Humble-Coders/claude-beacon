import Foundation

/// Shared filesystem locations for the whole app. Mirrors the paths the
/// `beacon-hook` shell script writes to.
enum BeaconPaths {
    static let home: URL = {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_BEACON_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-beacon", isDirectory: true)
    }()

    static var events: URL { home.appendingPathComponent("events", isDirectory: true) }
    static var state: URL { home.appendingPathComponent("state.json", isDirectory: false) }
    static var log: URL { home.appendingPathComponent("beacon.log", isDirectory: false) }

    /// Ensure the base directories exist.
    static func ensure() {
        try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    }
}

/// Timestamped logger shared with the hook script (same beacon.log file).
enum Log {
    private static let queue = DispatchQueue(label: "com.humble.claudebeacon.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) [app] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = BeaconPaths.log
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        #if DEBUG
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        #endif
    }
}
