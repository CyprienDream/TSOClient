import Foundation
import Observation

@Observable
final class BuffsStore {
    var items: [BuffItem] = []

    // Bumped on every `apply` so views can equate against this instead of
    // walking the items array.
    private(set) var version: Int = 0
    // Indices rebuilt in `apply` so panel reads are O(1) dict hits.
    private(set) var byBuffName: [String: BuffItem] = [:]
    private(set) var totalAmountByName: [String: Int] = [:]
    private(set) var cachedUniqueTypes: [BuffItem] = []

    struct BuffItem: Identifiable {
        var id: String { "\(uid1):\(uid2)" }
        let uid1: Int
        let uid2: Int
        let buffName: String        // raw name, e.g. "HiredMilitary"
        let resourceName: String    // e.g. "Recruit" (empty string when not applicable)
        let amount: Int
        let insertedAt: Int         // Unix timestamp
        let displayName: String     // computed once at apply (was per-render char loop)

        // Just the name — amount is shown separately in the panel's inventory line.
        var displayLabel: String { displayName }

        static let knownNames: [String: String] = [
            "ProductivityBuffLvl300": "Aunt Irma's Feast",
            "ProductivityBuffLvl3":   "Aunt Irma's Basket",
            "ProductivityBuffLvl10":  "Stadium Snacks",
        ]

        static func computeDisplayName(_ buffName: String) -> String {
            if let known = knownNames[buffName] { return known }
            var out = ""
            for (i, ch) in buffName.enumerated() {
                if i > 0 && ch.isUppercase { out.append(" ") }
                out.append(ch)
            }
            return out.isEmpty ? buffName : out
        }
    }

    // O(1) snapshot of the cached unique-type list. Sorted by displayName.
    var uniqueTypes: [BuffItem] { cachedUniqueTypes }

    // O(1) cached lookups.
    func totalAmount(for name: String) -> Int { totalAmountByName[name] ?? 0 }
    func item(for name: String) -> BuffItem? { byBuffName[name] }

    func apply(_ payload: InboundMessage.BuffsPayload) {
        let newItems: [BuffItem] = payload.items.map {
            BuffItem(
                uid1:         $0.uid1,
                uid2:         $0.uid2,
                buffName:     $0.buffName,
                resourceName: $0.resourceName,
                amount:       $0.amount,
                insertedAt:   $0.insertedAt,
                displayName:  BuffItem.computeDisplayName($0.buffName)
            )
        }
        var byName: [String: BuffItem] = [:]
        var amount: [String: Int] = [:]
        for it in newItems {
            if byName[it.buffName] == nil { byName[it.buffName] = it }
            amount[it.buffName, default: 0] += it.amount
        }
        items = newItems
        byBuffName = byName
        totalAmountByName = amount
        cachedUniqueTypes = byName.values.sorted { $0.displayName < $1.displayName }
        version &+= 1
    }

    func clear() {
        items = []
        byBuffName = [:]
        totalAmountByName = [:]
        cachedUniqueTypes = []
        version &+= 1
    }
}
