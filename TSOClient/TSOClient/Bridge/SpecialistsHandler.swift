import Foundation

struct SpecialistsHandler: InboundMessageHandler {
    let store: SpecialistsStore
    let coordinator: SpecialistDispatchCoordinator
    let logger: Logger
    var type: String { "SPECIALISTS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.SpecialistsPayload.self, from: payloadData)
        store.apply(payload)
        logger.log("[TSO] Specialists received: \(payload.items.count)")
        coordinator.runAutoExplorerLoop()
        coordinator.runAutoGeologistLoop()
    }
}
