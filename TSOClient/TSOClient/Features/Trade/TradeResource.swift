import Foundation

// Curated list of resources commonly used in bank trades. The wire field
// is `dResourceVO.name_string` — these strings must match the game's
// internal asset names exactly (verified for "Tool" / "Wood" from a live
// capture; the rest mirror conventions seen in explorer/geo task data
// and the resource hints in the existing logs).
struct TradeResource: Identifiable, Hashable {
    let name: String        // wire value, e.g. "Tool"
    let displayName: String // panel label, e.g. "Tools"

    var id: String { name }
}

enum TradeResourceCatalog {
    static let all: [TradeResource] = [
        // Raw / mined
        TradeResource(name: "Wood",        displayName: "Wood"),
        TradeResource(name: "Stone",       displayName: "Stone"),
        TradeResource(name: "Marble",      displayName: "Marble"),
        TradeResource(name: "Granite",     displayName: "Granite"),
        TradeResource(name: "Coal",        displayName: "Coal"),
        TradeResource(name: "Copper",      displayName: "Copper Ore"),
        TradeResource(name: "Iron",        displayName: "Iron Ore"),
        TradeResource(name: "Gold",        displayName: "Gold Ore"),
        TradeResource(name: "Titanium",    displayName: "Titanium Ore"),
        TradeResource(name: "Salpeter",    displayName: "Salpeter"),
        // Processed
        TradeResource(name: "Plank",       displayName: "Planks"),
        TradeResource(name: "Tool",        displayName: "Tools"),
        TradeResource(name: "Bronze",      displayName: "Bronze"),
        TradeResource(name: "Steel",       displayName: "Steel"),
        TradeResource(name: "GoldCoin",    displayName: "Gold Coins"),
        TradeResource(name: "Gunpowder",   displayName: "Gunpowder"),
        // Food
        TradeResource(name: "Bread",       displayName: "Bread"),
        TradeResource(name: "Sausage",     displayName: "Sausage"),
        TradeResource(name: "Beer",        displayName: "Beer"),
        TradeResource(name: "Fish",        displayName: "Fish"),
        TradeResource(name: "Meat",        displayName: "Meat"),
        TradeResource(name: "Cheese",      displayName: "Cheese"),
        // Inputs
        TradeResource(name: "Wheat",       displayName: "Wheat"),
        TradeResource(name: "Water",       displayName: "Water"),
        TradeResource(name: "Flour",       displayName: "Flour"),
        TradeResource(name: "Corn",        displayName: "Corn"),
        TradeResource(name: "Hop",         displayName: "Hop"),
        TradeResource(name: "Pig",         displayName: "Pig"),
    ]

    // O(1) lookup for default selection / validation.
    static let byName: [String: TradeResource] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )
}
