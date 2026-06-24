import Foundation
import Observation

@Observable
final class BuildingsStore {
    var items: [BuildingItem] = []
    // skinBase → buildings, sorted by gridIndex. Rebuilt in `apply` so panel
    // lookups are O(1) dict hits instead of O(N) filters + regex per render.
    private(set) var bySkinBase: [String: [BuildingItem]] = [:]

    private let normalizer: BuildingSkinNormalizer

    init(normalizer: BuildingSkinNormalizer = .default) {
        self.normalizer = normalizer
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

    // Buildings matching a skin filter, grouped by skinBase, sorted by name then grid.
    // Pass nil to get all buildings.
    func grouped(containing filter: String?) -> [(skin: String, buildings: [BuildingItem])] {
        var groups: [String: [BuildingItem]] = [:]
        for b in items {
            if let f = filter, !b.skinBase.localizedCaseInsensitiveContains(f) { continue }
            groups[b.skinBase, default: []].append(b)
        }
        return groups
            .sorted { $0.key < $1.key }
            .map { (skin: $0.key, buildings: $0.value.sorted { $0.gridIndex < $1.gridIndex }) }
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
    }

    func clear() {
        items = []
        bySkinBase = [:]
    }
}
