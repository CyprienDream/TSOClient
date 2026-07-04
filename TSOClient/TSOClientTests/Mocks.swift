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

    func bool(forKey key: String) -> Bool {
        storage[key] as? Bool ?? false
    }

    func string(forKey key: String) -> String? {
        storage[key] as? String
    }

    func object(forKey key: String) -> Any? {
        storage[key]
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

// DurationEstimator backed by a closure so tests can pass arbitrary estimate
// behavior. timeBonus is fixed at 100 (matching non-explorer subtypes) since
// no current test exercises bonus-aware learning paths.
final class FakeDurationEstimator: DurationEstimator {
    var estimateFn: (TaskCode, Int, [SpecialistSkill]) -> TimeInterval?

    init(_ estimateFn: @escaping (TaskCode, Int, [SpecialistSkill]) -> TimeInterval?) {
        self.estimateFn = estimateFn
    }

    func estimate(task: TaskCode,
                  subTypeId: Int,
                  skills: [SpecialistSkill],
                  pfbActive: Bool) -> TimeInterval? {
        estimateFn(task, subTypeId, skills)
    }

    func timeBonus(subTypeId: Int, task: TaskCode?) -> Int { 100 }
}

// Records every command the coordinators try to dispatch. Conforms to all
// three dispatch ports so a single instance works for specialist + buff +
// trade tests. Synthesises the real WireCommand structs so tests can keep
// asserting via `as? DispatchSpecialistCommand` / etc.
final class CapturingDispatcher: SpecialistDispatchPort, BuffDispatchPort, TradeDispatchPort {
    private(set) var sent: [WireCommand] = []

    func dispatchSpecialist(uid1: Int,
                            uid2: Int,
                            actionType: Int,
                            subTaskID: Int,
                            targetGrid: Int) {
        sent.append(DispatchSpecialistCommand(
            uid1: uid1, uid2: uid2,
            actionType: actionType, subTaskID: subTaskID,
            targetGrid: targetGrid))
    }

    func dispatchBuff(buffUid1: Int, buffUid2: Int, targetGrid: Int) {
        sent.append(DispatchBuffCommand(
            buffUid1: buffUid1, buffUid2: buffUid2,
            targetGrid: targetGrid))
    }

    func dispatchTrade(receipientId: Int,
                       offerResource: String, offerAmount: Int,
                       costsResource: String, costsAmount: Int,
                       lots: Int,
                       slotType: Int) {
        sent.append(DispatchTradeCommand(
            receipientId: receipientId,
            offerResource: offerResource, offerAmount: offerAmount,
            costsResource: costsResource, costsAmount: costsAmount,
            lots: lots,
            slotType: slotType))
    }
}

// In-memory JSON file store keyed by filename. Used by ResourcesStore tests
// to drive load/save without touching Application Support.
final class MockJSONFileStore: JSONFileStoring {
    var files: [String: Data] = [:]
    private(set) var writes: [(filename: String, bytes: Int)] = []

    func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        guard let data = files[filename] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to filename: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        files[filename] = data
        writes.append((filename, data.count))
    }
}

// Counts calls to the SpecialistsHandler's auto-loop runner so tests can
// assert the handler kicks off sweeps after each apply.
final class FakeAutoLoopRunner: SpecialistsAutoLoopRunner {
    private(set) var explorerSweepCount = 0
    private(set) var geologistSweepCount = 0

    func runAutoExplorerLoop() -> Task<Void, Never>? {
        explorerSweepCount += 1
        return nil
    }

    func runAutoGeologistLoop() {
        geologistSweepCount += 1
    }
}
