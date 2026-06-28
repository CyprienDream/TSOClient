import Foundation
import Observation

@Observable
final class BuildingsStore {
    static let persistenceFilename = "building-skins.json"

    // On-disk shape: { "version": 1, "skinBases": ["Mason", "Woodcutter", ...] }.
    struct Persisted: Codable {
        var version: Int
        var skinBases: [String]
    }

    var items: [BuildingItem] = []
    // skinBase → buildings, sorted by gridIndex. Rebuilt in `apply` so panel
    // lookups are O(1) dict hits instead of O(N) filters + regex per render.
    private(set) var bySkinBase: [String: [BuildingItem]] = [:]
    // Union of every wire-confirmed skinBase observed across launches.
    // Persisted; only grows.
    private(set) var seenSkinBases: Set<String> = []
    // Hash of the last applied payload — when the game re-sends an identical
    // buildings list (common on heartbeats) we skip the rebuild + observer notify.
    private var lastFingerprint: Int?

    private let normalizer: BuildingSkinNormalizer
    private let store: JSONFileStoring
    private let logger: Logger

    init(normalizer: BuildingSkinNormalizer = .default,
         store: JSONFileStoring = JSONFileStore(),
         logger: Logger = ConsoleLogger()) {
        self.normalizer = normalizer
        self.store = store
        self.logger = logger
        if let persisted = store.load(Persisted.self, from: Self.persistenceFilename) {
            seenSkinBases = Set(persisted.skinBases)
        }
    }

    struct BuildingItem: Identifiable {
        var id: String { "\(uid1):\(uid2)" }
        let gridIndex: Int
        let skin: String        // raw skin name, e.g. "Woodcutter_01"
        let skinBase: String    // skin with trailing "_NN" stripped — computed once at apply.
        let uid1: Int
        let uid2: Int
        let activeBuff: String? // buffName_string of first active buff, nil if unbuffed
    }

    // All buildings whose skinBase is any of `bases`, sorted by gridIndex.
    // Backed by the prebuilt index — safe to call from view bodies.
    func buildings(matchingSkinBases bases: [String]) -> [BuildingItem] {
        var out: [BuildingItem] = []
        for base in bases {
            if let bucket = bySkinBase[base] { out.append(contentsOf: bucket) }
        }
        if bases.count > 1 { out.sort { $0.gridIndex < $1.gridIndex } }
        return out
    }

    func apply(_ payload: InboundMessage.BuildingsPayload) {
        let fingerprint = Self.fingerprint(of: payload.items)
        if fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint
        let newItems: [BuildingItem] = payload.items.map {
            BuildingItem(
                gridIndex: $0.gridIndex,
                skin: $0.skin,
                skinBase: normalizer.base(of: $0.skin),
                uid1: $0.uid1,
                uid2: $0.uid2,
                activeBuff: $0.activeBuff
            )
        }
        var index: [String: [BuildingItem]] = [:]
        for it in newItems {
            index[it.skinBase, default: []].append(it)
        }
        for k in index.keys {
            index[k]?.sort { $0.gridIndex < $1.gridIndex }
        }
        items = newItems
        bySkinBase = index

        let before = seenSkinBases.count
        seenSkinBases.formUnion(index.keys)
        if seenSkinBases.count > before {
            persist(seenSkinBases)
            logger.log("[Buildings] +\(seenSkinBases.count - before) new skinBase(s) (\(seenSkinBases.count) total)")
        }
    }

    private func persist(_ bases: Set<String>) {
        store.save(
            Persisted(version: 1, skinBases: bases.sorted()),
            to: Self.persistenceFilename
        )
    }

    func clear() {
        items = []
        bySkinBase = [:]
        lastFingerprint = nil
    }

    private static func fingerprint(of items: [InboundMessage.BuildingsPayload.Item]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for it in items {
            hasher.combine(it.gridIndex)
            hasher.combine(it.uid1)
            hasher.combine(it.uid2)
            hasher.combine(it.skin)
            hasher.combine(it.activeBuff)
        }
        return hasher.finalize()
    }
}
