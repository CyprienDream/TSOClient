import Foundation

// Maps decoded InboundMessage values to store mutations.
// Single Responsibility: the coordinator receives raw script messages and
// delegates all store-update logic here.
final class BridgeRouter {

    let collectibles: CollectiblesStore
    let specialists: SpecialistsStore
    let buildings: BuildingsStore
    let buffs: BuffsStore

    init(collectibles: CollectiblesStore, specialists: SpecialistsStore,
         buildings: BuildingsStore, buffs: BuffsStore) {
        self.collectibles = collectibles
        self.specialists = specialists
        self.buildings = buildings
        self.buffs = buffs
    }

    func route(_ msg: InboundMessage) {
        switch msg {
        case .collectibles(let payload):
            collectibles.apply(payload)
        case .gameState(let payload):
            print("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
            if payload.state == "ZONE_LEFT" {
                collectibles.clear()
                specialists.clear()
                buildings.clear()
                buffs.clear()
            }
        case .specialists(let payload):
            specialists.apply(payload)
            print("[TSO] Specialists received: \(payload.items.count)")
        case .buildings(let payload):
            buildings.apply(payload)
            print("[TSO] Buildings received: \(payload.items.count)")
        case .buffs(let payload):
            buffs.apply(payload)
            print("[TSO] Buffs received: \(payload.items.count)")
        }
    }
}
