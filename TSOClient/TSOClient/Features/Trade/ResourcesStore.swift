import Foundation
import Observation

// Accumulates wire-confirmed resource names (dResourceVO.name_string and
// the LHS of dTradeObjectVO offer strings) and persists them across
// launches as a JSON file under Application Support. Seeded with
// TradeResourceCatalog so the dropdowns aren't empty on a fresh install.
// Wire-confirmed names take precedence visually because they're what the
// server actually accepts.
@Observable
final class ResourcesStore {
    static let persistenceFilename = "trade-resources.json"
    // UserDefaults key from v1 persistence — migrated then deleted so we
    // don't lose names already accumulated under the old scheme.
    private static let legacyUserDefaultsKey = "tso.tradeResources.wireConfirmed.v1"

    // On-disk shape: { "version": 1, "names": ["Tool", "Wood", ...] }.
    struct Persisted: Codable {
        var version: Int
        var names: [String]
    }

    // Names confirmed from the wire — persisted, only grows.
    private var wireConfirmed: Set<String> = []

    // Sorted snapshot for the panel: { name, displayName, confirmed }.
    private(set) var entries: [Entry] = []

    struct Entry: Identifiable, Hashable {
        var id: String { name }
        let name: String           // wire value, e.g. "Tool"
        let displayName: String    // panel label, e.g. "Tools"
        let confirmed: Bool        // true if seen on the wire this session or earlier
    }

    private let store: JSONFileStoring
    private let legacyKV: KeyValueStore?
    private let logger: Logger

    init(store: JSONFileStoring = JSONFileStore(),
         legacyKV: KeyValueStore? = UserDefaultsKeyValueStore(),
         logger: Logger = ConsoleLogger()) {
        self.store = store
        self.legacyKV = legacyKV
        self.logger = logger
        wireConfirmed = loadInitial()
        rebuild()
    }

    private func loadInitial() -> Set<String> {
        if let persisted = store.load(Persisted.self, from: Self.persistenceFilename) {
            return Set(persisted.names)
        }
        // Migrate any pre-existing UserDefaults catalog so an upgrade
        // doesn't lose names accumulated under the v1 scheme.
        if let legacy = legacyKV?.object(forKey: Self.legacyUserDefaultsKey) as? [String],
           !legacy.isEmpty {
            let names = Set(legacy)
            persist(names)
            legacyKV?.set(nil, forKey: Self.legacyUserDefaultsKey)
            logger.log("[Resources] migrated \(names.count) names from UserDefaults to \(Self.persistenceFilename)")
            return names
        }
        return []
    }

    func apply(_ payload: InboundMessage.ResourcesPayload) {
        let before = wireConfirmed.count
        wireConfirmed.formUnion(payload.names)
        guard wireConfirmed.count > before else { return }
        persist(wireConfirmed)
        rebuild()
        logger.log("[Resources] +\(wireConfirmed.count - before) new (\(wireConfirmed.count) total)")
    }

    private func persist(_ names: Set<String>) {
        store.save(
            Persisted(version: 1, names: names.sorted()),
            to: Self.persistenceFilename
        )
    }

    // Union of curated catalog ∪ wire-confirmed, sorted by displayName.
    // Wire-confirmed entries are marked so the panel can surface that hint.
    private func rebuild() {
        var byName: [String: Entry] = [:]
        for r in TradeResourceCatalog.all {
            byName[r.name] = Entry(name: r.name, displayName: r.displayName,
                                   confirmed: wireConfirmed.contains(r.name))
        }
        for name in wireConfirmed where byName[name] == nil {
            byName[name] = Entry(
                name: name,
                displayName: humanize(name),
                confirmed: true
            )
        }
        entries = byName.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // Insert spaces between camelCase / between letter/digit boundaries so a
    // raw wire name like "EMEventResource" displays as "EM Event Resource".
    // The "Collectible" prefix is dropped from the label — the wire still
    // sees the full name, but the dropdown shows "Clue" instead of
    // "Collectible Clue", since every entry in that family is one.
    private func humanize(_ raw: String) -> String {
        let stripped = raw.hasPrefix("Collectible") && raw.count > "Collectible".count
            ? String(raw.dropFirst("Collectible".count))
            : raw
        var result = ""
        for (i, ch) in stripped.enumerated() {
            if i > 0,
               let prev = stripped[stripped.index(stripped.startIndex, offsetBy: i - 1)].unicodeScalars.first,
               let cur  = ch.unicodeScalars.first,
               (CharacterSet.lowercaseLetters.contains(prev) && CharacterSet.uppercaseLetters.contains(cur)) ||
               (CharacterSet.letters.contains(prev) && CharacterSet.decimalDigits.contains(cur)) {
                result.append(" ")
            }
            result.append(ch)
        }
        return result
    }
}
