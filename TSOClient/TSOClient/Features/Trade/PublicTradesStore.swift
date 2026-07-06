import Foundation
import Observation

// Own active public trades, snapshot from opcode 1062. Rebuilt whole every
// apply — the wire semantics are "here's your full trade window right now",
// so we don't try to merge deltas. The panel indexes by `id`; cancel opcode
// 1056 dispatches on that id.
@Observable
final class PublicTradesStore {
    private(set) var items: [PublicTrade] = []
    private(set) var version: Int = 0

    private var lastFingerprint: Int?

    struct PublicTrade: Identifiable, Hashable {
        var id: Int { tradeId }
        let tradeId: Int          // dTradeObjectVO.id — used by cancel opcode
        let slotType: Int
        let slotPos: Int
        let type: Int
        let offer: String         // pipe-encoded raw offer string
        let remainingTime: Int    // ms until expiration
        let lotsRemaining: Int
    }

    func apply(_ payload: InboundMessage.PublicTradesPayload) {
        let fingerprint = Self.fingerprint(of: payload.items)
        if fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint
        items = payload.items
            .map {
                PublicTrade(
                    tradeId:       $0.id,
                    slotType:      $0.slotType,
                    slotPos:       $0.slotPos,
                    type:          $0.type,
                    offer:         $0.offer,
                    remainingTime: $0.remainingTime,
                    lotsRemaining: $0.lotsRemaining
                )
            }
            .sorted { ($0.slotType, $0.slotPos) < ($1.slotType, $1.slotPos) }
        version &+= 1
    }

    // Optimistic removal for the cancel button. The next 1062 snapshot
    // reconfirms; if the server refused, the row re-appears.
    func remove(tradeId: Int) {
        guard items.contains(where: { $0.tradeId == tradeId }) else { return }
        items.removeAll { $0.tradeId == tradeId }
        lastFingerprint = nil
        version &+= 1
    }

    func clear() {
        items = []
        lastFingerprint = nil
        version &+= 1
    }

    private static func fingerprint(of items: [InboundMessage.PublicTradesPayload.Item]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for it in items {
            hasher.combine(it.id)
            hasher.combine(it.slotType)
            hasher.combine(it.slotPos)
            hasher.combine(it.offer)
            hasher.combine(it.remainingTime)
            hasher.combine(it.lotsRemaining)
        }
        return hasher.finalize()
    }
}
