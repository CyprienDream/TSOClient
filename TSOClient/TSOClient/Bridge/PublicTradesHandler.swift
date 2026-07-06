import Foundation

struct PublicTradesHandler: InboundMessageHandler {
    let store: PublicTradesStore
    let logger: Logger
    var type: String { "PUBLIC_TRADES" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.PublicTradesPayload.self, from: payloadData)
        store.apply(payload)
        logger.log("[TSO] Public trades received: \(payload.items.count)")
    }
}
