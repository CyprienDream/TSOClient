import Foundation

// Concrete InboundMessageHandler implementations, one per message type.
// Decoding is delegated to JSONDecoder; the handler then forwards the typed
// payload to the appropriate store.

struct CollectiblesHandler: InboundMessageHandler {
    let store: CollectiblesStore
    var type: String { "COLLECTIBLES" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.CollectiblesPayload.self, from: payloadData)
        store.apply(payload)
    }
}

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

// Updates SpecialistsStore.pfbActive from the JS auto-detection scan.
// Logs every transition so the user can verify detection is working.
struct PlayerBuffsHandler: InboundMessageHandler {
    let store: SpecialistsStore
    let logger: Logger
    var type: String { "PLAYER_BUFFS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.PlayerBuffsPayload.self, from: payloadData)
        let was = store.pfbActive
        store.pfbActive = payload.pfbActive
        if was != payload.pfbActive {
            logger.log("[TSO] PFB \(payload.pfbActive ? "ACTIVE" : "inactive") (auto-detected)")
        }
    }
}

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

// Listens for ZONE_LEFT and clears every per-zone store. The list of stores
// to clear is closed by construction — passing them in keeps the handler
// dependent on its collaborators rather than a god-bag.
struct GameStateHandler: InboundMessageHandler {
    let collectibles: CollectiblesStore
    let specialists: SpecialistsStore
    let buildings: BuildingsStore
    let buffs: BuffsStore
    let logger: Logger

    var type: String { "GAME_STATE" }

    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.GameStatePayload.self, from: payloadData)
        logger.log("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
        if payload.state == "ZONE_LEFT" {
            collectibles.clear()
            specialists.clear()
            buildings.clear()
            buffs.clear()
        }
    }
}
