import Foundation

// Handles the ZONE_CONTEXT bridge message emitted by amf3-scanner on every
// home ↔ friend ↔ adventure transition. When context flips off 'home', the
// buff panel needs to keep functioning (targeting the friend's buildings),
// but the specialists panel and collectibles view need to blank so the user
// can't dispatch a specialist against a zoneID that isn't theirs, and so
// stale home markers don't leak onto a friend's map.
//
// Blanking SpecialistsStore.items also pauses auto-loop wake timers
// implicitly: SpecialistDispatchCoordinator.fireReDispatch re-reads
// store.items at wake time and bails if the uid isn't present.
//
// On return to 'home', the next home zone-load response repopulates every
// store, so this handler is a no-op — the ZONE_CONTEXT emit is purely a
// wipe signal.
struct ZoneContextHandler: InboundMessageHandler {
    let offHomeStoresToClear: [ZoneLifecycle]
    let logger: Logger

    var type: String { "ZONE_CONTEXT" }

    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.ZoneContextPayload.self, from: payloadData)
        logger.log("[TSO] Zone context: \(payload.context) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
        if payload.context != "home" {
            for store in offHomeStoresToClear { store.clear() }
        }
    }
}
