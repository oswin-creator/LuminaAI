import Foundation
import AppKit

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published var recentLogText: String = ""
    @Published var currentLineCount: Int = 0

    let logDirectoryURL: URL
    let logFileURL: URL

    private let queue = DispatchQueue(label: "com.lumina.ai.logger", qos: .utility)
    private let dateFormatter: DateFormatter

    // Rate-limit & deduplication protection to prevent runaway error loops
    private var lastMessageKey: String = ""
    private var lastMessageTime: Date = .distantPast
    private var writeCountSincePrune: Int = 0
    private var windowStartTime: Date = Date()
    private var writesInCurrentWindow: Int = 0

    private init() {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.logDirectoryURL = libraryURL.appendingPathComponent("Logs/LuminaAI", isDirectory: true)
        self.logFileURL = logDirectoryURL.appendingPathComponent("lumina.log")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.dateFormatter = df

        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        pruneNow()
    }

    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }

    func log(_ level: LogLevel, _ message: String) {
        let now = Date()
        let key = "\(level.rawValue):\(message)"

        queue.async { [weak self] in
            guard let self = self else { return }

            // 1. Suppress identical rapid repeats within 3 seconds
            if key == self.lastMessageKey && now.timeIntervalSince(self.lastMessageTime) < 3.0 {
                return
            }

            // 2. Burst rate-limit: max 20 log lines per 5 seconds to prevent disk flooding
            if now.timeIntervalSince(self.windowStartTime) > 5.0 {
                self.windowStartTime = now
                self.writesInCurrentWindow = 0
            }
            self.writesInCurrentWindow += 1
            if self.writesInCurrentWindow > 20 {
                return
            }

            self.lastMessageKey = key
            self.lastMessageTime = now

            let timestamp = self.dateFormatter.string(from: now)
            let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: self.logFileURL, options: .atomic)
                }
            }

            self.writeCountSincePrune += 1
            if self.writeCountSincePrune >= 25 {
                self.writeCountSincePrune = 0
                self.pruneOnQueue()
            } else {
                self.reloadOnQueue()
            }
        }
    }

    func pruneNow() {
        queue.async { [weak self] in
            self?.pruneOnQueue()
        }
    }

    func reloadRecentLogs() {
        queue.async { [weak self] in
            self?.reloadOnQueue()
        }
    }

    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.recentLogText = ""
                self.currentLineCount = 0
            }
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    private func pruneOnQueue() {
        let retention = SettingsStore.shared.logRetentionPeriod.timeInterval
        let maxLines = max(50, SettingsStore.shared.logMaxLines)
        let cutoff = Date().addingTimeInterval(-retention)

        // Hard 2MB safety cap before reading
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64,
           size > 2 * 1024 * 1024 {
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }

        let raw = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
        var lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Filter out lines older than retention window
        lines = lines.filter { line in
            guard line.hasPrefix("["), line.count >= 21 else { return true }
            let startIdx = line.index(after: line.startIndex)
            let endIdx = line.index(startIdx, offsetBy: 19)
            let tsStr = String(line[startIdx..<endIdx])
            if let date = dateFormatter.date(from: tsStr) {
                return date >= cutoff
            }
            return true
        }

        // Enforce max line count cap
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        let joined = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? joined.write(to: logFileURL, atomically: true, encoding: .utf8)

        let displayLines = lines.suffix(300).joined(separator: "\n")
        let count = lines.count
        DispatchQueue.main.async {
            self.recentLogText = displayLines
            self.currentLineCount = count
        }
    }

    private func reloadOnQueue() {
        let content = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let display = lines.suffix(300).joined(separator: "\n")
        let count = lines.count
        DispatchQueue.main.async {
            self.recentLogText = display
            self.currentLineCount = count
        }
    }
}
