import Foundation

// Listens for ZONE_LEFT and clears every per-zone store. The list of stores
// to clear is closed by construction — passing them in keeps the handler
// dependent on its collaborators rather than a god-bag.
struct GameStateHandler: InboundMessageHandler {
    let collectibles: CollectiblesStore
    let specialists: SpecialistsStore
    let buildings: BuildingsStore
    let buffs: BuffsStore
    let logger: Logger

    var type: String { "GAME_STATE" }

    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.GameStatePayload.self, from: payloadData)
        logger.log("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
        if payload.state == "ZONE_LEFT" {
            collectibles.clear()
            specialists.clear()
            buildings.clear()
            buffs.clear()
        }
    }
}
