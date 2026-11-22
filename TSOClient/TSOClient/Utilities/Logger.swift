import Foundation
import os

protocol Logger {
    func log(_ message: String)
}

enum LogTimestamp {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func now() -> String { formatter.string(from: Date()) }
}

// Backed by os.Logger so messages stream through the unified-logging system
// instead of synchronous stderr. print() holds a global mutex and Xcode pins
// the full transcript in memory; both become measurable costs during the
// thousands of per-session log lines emitted by the AMF scanner pipeline.
struct ConsoleLogger: Logger {
    private static let osLogger = os.Logger(subsystem: "com.tsoclient", category: "app")
    func log(_ message: String) {
        Self.osLogger.log("\(message, privacy: .public)")
    }
}

// Fans a single log call out to multiple sinks. Used in production to tee
// ConsoleLogger (Xcode console) and FileLogger (tailable file) so the same
// stream shows up in both places without the call site caring.
struct TeeLogger: Logger {
    let loggers: [Logger]
    func log(_ message: String) {
        for l in loggers { l.log(message) }
    }
}

// Appends every log line to a session-scoped file so the running app's
// output can be tailed from a terminal (the sandbox blocks our os.Logger
// subsystem from surfacing via `log show`). The file is truncated per
// launch — one session per file. Silently no-ops if the file can't be
// opened so logging never crashes the app.
//
// Test-host detour: when the process is spawned by `xcodebuild test` the
// app binary still launches and `AppEnvironment` still runs, which would
// truncate the live `latest.log`. Detect the xctest harness via
// `XCTestConfigurationFilePath` and route to a sidecar `tests.log` so a
// running game session's log isn't clobbered by a test run.
final class FileLogger: Logger {
    let fileURL: URL?
    private let handle: FileHandle?
    private let lock = NSLock()

    static let liveFilename = "latest.log"
    static let testsFilename = "tests.log"

    static func defaultFilename(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        environment["XCTestConfigurationFilePath"] != nil ? testsFilename : liveFilename
    }

    init(filename: String = FileLogger.defaultFilename()) {
        guard let libraryDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first else {
            self.fileURL = nil
            self.handle  = nil
            return
        }
        let dir = libraryDir.appendingPathComponent("Logs/TSOClient", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)   // truncate
        self.fileURL = url
        self.handle = try? FileHandle(forWritingTo: url)
        if let handle {
            let header = "=== TSOClient session started \(LogTimestamp.now()) (\(filename)) ===\n"
            try? handle.write(contentsOf: Data(header.utf8))
        }
    }

    deinit {
        try? handle?.close()
    }

    func log(_ message: String) {
        guard let handle,
              let data = "[\(LogTimestamp.now())] \(message)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}
