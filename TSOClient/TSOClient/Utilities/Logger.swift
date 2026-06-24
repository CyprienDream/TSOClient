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
