import Foundation
@testable import TSOClient

// Captures every log line so assertions can verify what was emitted.
final class MockLogger: Logger {
    var messages: [String] = []
    func log(_ message: String) { messages.append(message) }
}

// In-memory KeyValueStore. Tracks every set so persistence assertions can
// look at history, not just the final state.
final class MockKeyValueStore: KeyValueStore {
    private(set) var storage: [String: Any] = [:]
    private(set) var setHistory: [(key: String, value: Any?)] = []

    func dictionary(forKey key: String) -> [String: Any]? {
        storage[key] as? [String: Any]
    }

    func set(_ value: Any?, forKey key: String) {
        setHistory.append((key, value))
        if let value { storage[key] = value }
        else { storage.removeValue(forKey: key) }
    }
}

// Loader backed by an in-memory map keyed "<name>.<ext>".
final class MockResourceLoader: ResourceLoader {
    var files: [String: Data] = [:]

    func loadData(name: String, ext: String) -> Data? {
        files["\(name).\(ext)"]
    }

    func setJSON(_ json: String, name: String, ext: String = "json") {
        files["\(name).\(ext)"] = json.data(using: .utf8)
    }
}

// Records every command sent so tests can assert on type and payload.
final class CapturingDispatcher: OutboundDispatching {
    private(set) var sent: [WireCommand] = []
    func send(_ command: WireCommand) { sent.append(command) }
}
