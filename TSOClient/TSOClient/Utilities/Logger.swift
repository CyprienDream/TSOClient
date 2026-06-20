import Foundation

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

struct ConsoleLogger: Logger {
    func log(_ message: String) { print("[\(LogTimestamp.now())] \(message)") }
}
