import Foundation

// Fires on the server-authoritative "geologist finished" push
// (`dGameTickCommandVO(mode=160, data=dFoundDepositVO)`, wrapped in a
// type=1004 heartbeat envelope). One payload can carry several completions
// — the server bundles simultaneous finishes into one envelope.
//
// Flips each named uid to idle in the store (which invalidates the fingerprint,
// so a subsequent snapshot showing the spec still busy re-asserts truth), then
// re-kicks the auto-loop so any enabled geologist loop can immediately
// re-dispatch. Auto-loop's own `pendingReDispatches[uid]` timer is left alone:
// the fresh `dispatchOne` call from the sweep will cancel and replace it via
// its normal `scheduleAutoReDispatch` path.
struct SpecialistTaskCompletedHandler: InboundMessageHandler {
    let store: SpecialistsStore
    let autoLoop: SpecialistsAutoLoopRunner
    let logger: Logger
    var type: String { "SPECIALIST_TASK_COMPLETED" }

    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(
            InboundMessage.SpecialistTaskCompletedPayload.self, from: payloadData)
        for item in payload.items {
            store.markCompleted(uid: item.uid)
            logger.log("[TaskComplete] \(item.kind) uid=\(item.uid) " +
                       "found \(item.deposits.count) \(item.searchedFor) deposit(s)")
        }
        autoLoop.runAutoGeologistLoop()
        autoLoop.runAutoExplorerLoop()
    }
}
