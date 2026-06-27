import Testing
import Foundation
@testable import TSOClient

// Inbound handlers are mostly thin JSON-decode-then-apply wrappers; what's
// worth testing here is the *side effects* on top of apply — the wiring that
// the existing store/coordinator tests don't see.

private func encode(_ obj: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: obj)
}

@Suite("SpecialistsHandler")
struct SpecialistsHandlerTests {

    @Test func applyKicksOffExplorerAndGeologistSweepsOnce() throws {
        let store = SpecialistsStore()
        let auto  = FakeAutoLoopRunner()
        let handler = SpecialistsHandler(store: store, autoLoop: auto, logger: MockLogger())

        let payload: [String: Any] = [
            "items": [
                ["uid": "1:1", "uid1": 1, "uid2": 1,
                 "specialistType": "Geologist",
                 "subTypeId": 0, "name": "", "isIdle": true, "skills": []],
            ],
            "playerLevel": 10,
        ]
        try handler.apply(payloadData: encode(payload))

        #expect(store.items.count == 1)
        #expect(auto.explorerSweepCount == 1)
        #expect(auto.geologistSweepCount == 1)
    }

    @Test func malformedPayloadThrowsAndSkipsSweeps() {
        let store = SpecialistsStore()
        let auto  = FakeAutoLoopRunner()
        let handler = SpecialistsHandler(store: store, autoLoop: auto, logger: MockLogger())

        #expect(throws: (any Error).self) {
            try handler.apply(payloadData: Data("{not json".utf8))
        }
        #expect(auto.explorerSweepCount == 0)
        #expect(auto.geologistSweepCount == 0)
    }
}

@Suite("GameStateHandler")
struct GameStateHandlerTests {

    @Test func zoneLeftClearsAllRegisteredStores() throws {
        let collectibles = CollectiblesStore()
        let specs        = SpecialistsStore()
        let buildings    = BuildingsStore()
        let buffs        = BuffsStore(naming: .empty)

        // Seed each with a value so we can verify the wipe.
        collectibles.apply(.init(mapWidth: 1, mapHeight: 1,
                                 items: [.init(gridIndex: 0, x: 0, y: 0, assetName: "X")]))
        specs.apply(.init(items: [.init(uid: "1:1", uid1: 1, uid2: 1,
                                        specialistType: .geologist, subTypeId: 0,
                                        subTypeName: nil, name: "", isIdle: true, skills: [],
                                        collectedTime: nil, bonusTime: nil, taskEndTime: nil,
                                        taskActionType: nil, taskSubTaskId: nil)],
                          playerLevel: nil))
        buildings.apply(.init(items: [.init(gridIndex: 0, skin: "Mason_01",
                                            uid1: 0, uid2: 0, activeBuff: nil)]))
        buffs.apply(.init(items: [.init(uid1: 0, uid2: 0, buffName: "X",
                                        resourceName: "", amount: 1, insertedAt: 0)]))

        let handler = GameStateHandler(
            stores: [collectibles, specs, buildings, buffs],
            logger: MockLogger())
        try handler.apply(payloadData: encode(["state": "ZONE_LEFT", "zoneId": NSNull()]))

        #expect(collectibles.items.isEmpty)
        #expect(specs.items.isEmpty)
        #expect(buildings.items.isEmpty)
        #expect(buffs.items.isEmpty)
    }

    @Test func nonZoneLeftStatesDoNotClear() throws {
        let buffs = BuffsStore(naming: .empty)
        buffs.apply(.init(items: [.init(uid1: 1, uid2: 1, buffName: "X",
                                        resourceName: "", amount: 1, insertedAt: 0)]))
        let handler = GameStateHandler(stores: [buffs], logger: MockLogger())

        try handler.apply(payloadData: encode(["state": "LOADED", "zoneId": 12]))
        try handler.apply(payloadData: encode(["state": "ZONE_CHANGED", "zoneId": 13]))

        #expect(buffs.items.count == 1)
    }
}

@Suite("PlayerBuffsHandler")
struct PlayerBuffsHandlerTests {

    @Test func setsPfbActiveOnStore() throws {
        let store = SpecialistsStore()
        let handler = PlayerBuffsHandler(store: store, logger: MockLogger())

        try handler.apply(payloadData: encode(["pfbActive": true]))
        #expect(store.pfbActive == true)

        try handler.apply(payloadData: encode(["pfbActive": false]))
        #expect(store.pfbActive == false)
    }

    @Test func logsOnlyOnTransition() throws {
        let store = SpecialistsStore()
        let logger = MockLogger()
        let handler = PlayerBuffsHandler(store: store, logger: logger)

        try handler.apply(payloadData: encode(["pfbActive": true]))
        try handler.apply(payloadData: encode(["pfbActive": true]))   // same — no log
        try handler.apply(payloadData: encode(["pfbActive": false]))  // change — log

        let pfbLogs = logger.messages.filter { $0.contains("PFB") }
        #expect(pfbLogs.count == 2)
    }
}
