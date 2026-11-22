import Foundation

struct BuildingsHandler: InboundMessageHandler {
    let store: BuildingsStore
    // Nil means the auto-loop wiring isn't connected (tests that don't care
    // about the sweep path). In prod, AppEnvironment wires the coordinator.
    let autoLoop: BuffsAutoLoopRunner?
    let logger: Logger
    var type: String { "BUILDINGS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.BuildingsPayload.self, from: payloadData)
        store.apply(payload)
        logger.log("[TSO] Buildings received: \(payload.items.count)")
        autoLoop?.runAutoBuffSweep()
    }
}
