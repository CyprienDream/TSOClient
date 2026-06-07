import Foundation

// Maps decoded InboundMessage values to store mutations on the AppEnvironment.
// Single Responsibility: the coordinator receives raw script messages and
// delegates all store-update logic here.
final class BridgeRouter {

    let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func route(_ msg: InboundMessage) {
        switch msg {
        case .collectibles(let payload):
            env.collectibles.apply(payload)
        case .gameState(let payload):
            print("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
            if payload.state == "ZONE_LEFT" {
                env.collectibles.clear()
                env.specialists.clear()
                env.buildings.clear()
                env.buffs.clear()
            }
        case .specialists(let payload):
            env.specialists.apply(payload)
            print("[TSO] Specialists received: \(payload.items.count)")
        case .buildings(let payload):
            env.buildings.apply(payload)
            print("[TSO] Buildings received: \(payload.items.count)")
        case .buffs(let payload):
            env.buffs.apply(payload)
            print("[TSO] Buffs received: \(payload.items.count)")
        }
    }
}
