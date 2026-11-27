import Foundation

/// Plain-text log at ~/.fxmic/fxmic.log plus a state.json snapshot, so the app can be inspected from a terminal.
/// Readable by this user only. What you say is not written unless `logTranscripts` is on: see `text(_:)`.
enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fxmic")
    static let url = dir.appendingPathComponent("fxmic.log")
    private static let queue = DispatchQueue(label: "fxmic.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    /// Message text as it should appear in the log (and the system log): the words themselves only with
    /// `logTranscripts` on, otherwise just how many there were.
    static func text(_ s: String) -> String {
        if Settings.shared.logTranscripts { return s }
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        return words == 0 ? "(empty)" : "(\(words) word\(words == 1 ? "" : "s"))"
    }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        NSLog("[fxmic] %@", message)
        queue.async {
            privateFiles()
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                h.closeFile()
            }
        }
    }

    /// The folder and log are this user's only (700 and 600), also when an older version created them readable.
    private static var checkedPermissions = false
    private static func privateFiles() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard !checkedPermissions else { return }
        checkedPermissions = true
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func state(_ fields: [String: Any]) {
        var record = fields
        record["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        queue.async {
            privateFiles()
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                let stateURL = dir.appendingPathComponent("state.json")
                try? data.write(to: stateURL)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            }
        }
    }
}
