import Observation

@Observable
final class CollectiblesStore {

    // MARK: Map metadata
    var mapWidth:  Int = 0
    var mapHeight: Int = 0

    // MARK: Collectible items
    var items: [CollectibleItem] = []

    // MARK: Overlay settings (mutated by UI, read by JS via OutboundMessage)
    var overlayEnabled: Bool = true
    var overlayColor:   String = "#FFD700"

    struct CollectibleItem: Identifiable {
        let id:        Int     // gridIndex (unique within a zone)
        let x:         Int     // grid column
        let y:         Int     // grid row
        let assetName: String
    }

    // MARK: - Apply parsed game data

    func apply(_ payload: InboundMessage.CollectiblesPayload) {
        mapWidth  = payload.mapWidth
        mapHeight = payload.mapHeight
        items = payload.items.map {
            CollectibleItem(id: $0.gridIndex, x: $0.x, y: $0.y, assetName: $0.assetName)
        }
    }

    func clear() {
        items     = []
        mapWidth  = 0
        mapHeight = 0
    }
}
