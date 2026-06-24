import Foundation

struct BuildingsHandler: InboundMessageHandler {
    let store: BuildingsStore
    let logger: Logger
    var type: String { "BUILDINGS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.BuildingsPayload.self, from: payloadData)
        store.apply(payload)
        logger.log("[TSO] Buildings received: \(payload.items.count)")
    }
}
