import Foundation

struct BuffsHandler: InboundMessageHandler {
    let store: BuffsStore
    let logger: Logger
    var type: String { "BUFFS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.BuffsPayload.self, from: payloadData)
        store.apply(payload)
        logger.log("[TSO] Buffs received: \(payload.items.count)")
    }
}
