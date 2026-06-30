import Foundation

// Display-name overrides for resources whose wire name (`dResourceVO.name_string`)
// doesn't match the in-game label. Entries here win over the auto-humanized
// label in `ResourcesStore.rebuild`. Only add an entry when the override is
// wire-confirmed — the rest of the catalog is grown from live traffic.
struct TradeResource: Identifiable, Hashable {
    let name: String        // wire value, e.g. "Corn"
    let displayName: String // panel label, e.g. "Wheat"

    var id: String { name }
}

enum TradeResourceCatalog {
    static let all: [TradeResource] = [
        TradeResource(name: "Corn", displayName: "Wheat"),
    ]

    // O(1) lookup for default selection / validation.
    static let byName: [String: TradeResource] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )
}
