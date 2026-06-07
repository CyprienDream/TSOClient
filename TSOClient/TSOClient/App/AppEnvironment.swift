import Foundation

// Bag of the app's long-lived stores plus the Swift→JS sender. Created once
// in ContentView and threaded through WebView / BridgeRouter so feature views
// don't accumulate per-store init parameters. Field types are reference types
// (@Observable classes), so passing by value preserves identity.
struct AppEnvironment {
    let collectibles: CollectiblesStore
    let specialists: SpecialistsStore
    let buildings: BuildingsStore
    let buffs: BuffsStore
    let sender: BridgeSender

    init() {
        self.collectibles = CollectiblesStore()
        self.specialists = SpecialistsStore()
        self.buildings = BuildingsStore()
        self.buffs = BuffsStore()
        self.sender = BridgeSender()
    }
}
