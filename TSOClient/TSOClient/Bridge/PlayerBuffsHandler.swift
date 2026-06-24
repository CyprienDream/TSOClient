import Foundation

// Updates SpecialistsStore.pfbActive from the JS auto-detection scan.
// Logs every transition so the user can verify detection is working.
struct PlayerBuffsHandler: InboundMessageHandler {
    let store: SpecialistsStore
    let logger: Logger
    var type: String { "PLAYER_BUFFS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.PlayerBuffsPayload.self, from: payloadData)
        let was = store.pfbActive
        store.pfbActive = payload.pfbActive
        if was != payload.pfbActive {
            logger.log("[TSO] PFB \(payload.pfbActive ? "ACTIVE" : "inactive") (auto-detected)")
        }
    }
}
