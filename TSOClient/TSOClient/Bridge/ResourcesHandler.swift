import Foundation

struct ResourcesHandler: InboundMessageHandler {
    let store: ResourcesStore
    let logger: Logger
    var type: String { "RESOURCES" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.ResourcesPayload.self, from: payloadData)
        store.apply(payload)
    }
}
