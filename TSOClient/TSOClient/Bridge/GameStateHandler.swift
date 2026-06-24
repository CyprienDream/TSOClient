import Foundation

// Listens for ZONE_LEFT and clears every per-zone store. The list of stores
// to clear is supplied as `[ZoneLifecycle]` so adding a new per-zone store
// is a registration change at the composition root, not an edit here.
struct GameStateHandler: InboundMessageHandler {
    let stores: [ZoneLifecycle]
    let logger: Logger

    var type: String { "GAME_STATE" }

    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.GameStatePayload.self, from: payloadData)
        logger.log("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
        if payload.state == "ZONE_LEFT" {
            for store in stores { store.clear() }
        }
    }
}
