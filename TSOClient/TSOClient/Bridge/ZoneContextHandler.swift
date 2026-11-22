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
// Narrow seam the handler uses to notify the buff coordinator of the current
// context. Keeps ZoneContextHandler decoupled from BuffDispatchCoordinator's
// surface — tests swap in a capturing fake.
protocol BuffZoneContextSink: AnyObject {
    func setZoneContext(_ context: String)
}

struct ZoneContextHandler: InboundMessageHandler {
    let offHomeStoresToClear: [ZoneLifecycle]
    let buffContext: BuffZoneContextSink?
    let logger: Logger

    init(offHomeStoresToClear: [ZoneLifecycle],
         buffContext: BuffZoneContextSink? = nil,
         logger: Logger) {
        self.offHomeStoresToClear = offHomeStoresToClear
        self.buffContext = buffContext
        self.logger = logger
    }

    var type: String { "ZONE_CONTEXT" }

    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.ZoneContextPayload.self, from: payloadData)
        logger.log("[TSO] Zone context: \(payload.context) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
        // Always notify the buff coordinator so it can swap its per-category
        // selection map (home ↔ friend). The off-home store-wipe below
        // remains conditional on non-home context.
        buffContext?.setZoneContext(payload.context)
        if payload.context != "home" {
            for store in offHomeStoresToClear { store.clear() }
        }
    }
}
