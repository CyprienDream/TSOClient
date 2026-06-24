import Foundation

struct CollectiblesHandler: InboundMessageHandler {
    let store: CollectiblesStore
    var type: String { "COLLECTIBLES" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.CollectiblesPayload.self, from: payloadData)
        store.apply(payload)
    }
}
