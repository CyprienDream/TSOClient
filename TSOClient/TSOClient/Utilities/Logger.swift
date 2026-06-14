import Foundation

protocol Logger {
    func log(_ message: String)
}

struct ConsoleLogger: Logger {
    func log(_ message: String) { print(message) }
}
