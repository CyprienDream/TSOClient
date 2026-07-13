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
        let publicTrades = PublicTradesStore()

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
        publicTrades.apply(.init(items: [.init(id: 1, slotType: 0, slotPos: 0, type: 0,
                                               offer: "A|B|1", remainingTime: 0, lotsRemaining: 1)]))

        let handler = GameStateHandler(
            stores: [collectibles, specs, buildings, buffs, publicTrades],
            logger: MockLogger())
        try handler.apply(payloadData: encode(["state": "ZONE_LEFT", "zoneId": NSNull()]))

        #expect(collectibles.items.isEmpty)
        #expect(specs.items.isEmpty)
        #expect(buildings.items.isEmpty)
        #expect(buffs.items.isEmpty)
        #expect(publicTrades.items.isEmpty)
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

@Suite("ZoneContextHandler")
struct ZoneContextHandlerTests {

    // Buff panel activation on friend visits: BUILDINGS + BUFFS keep flowing
    // via the loosened scanner gate, but the specialists + collectibles
    // stores need to blank so their panels don't show stale home data with
    // dispatch buttons that'd misfire against the friend's zoneID.

    @Test func friendContextClearsSpecialistsAndCollectibles() throws {
        let collectibles = CollectiblesStore()
        let specs        = SpecialistsStore()
        let buildings    = BuildingsStore()
        let buffs        = BuffsStore(naming: .empty)

        // Seed stores with a home snapshot; ZONE_CONTEXT=friend must wipe
        // specs + collectibles, and leave buildings + buffs alone (they
        // will be replaced by the friend-zone payload that arrives right
        // after this ZONE_CONTEXT message).
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

        let handler = ZoneContextHandler(
            offHomeStoresToClear: [specs, collectibles],
            logger: MockLogger())
        try handler.apply(payloadData: encode(["context": "friend", "zoneId": 8888]))

        #expect(specs.items.isEmpty)
        #expect(collectibles.items.isEmpty)
        // Not wiped — buff panel needs these to keep flowing on friend zones.
        #expect(buildings.items.count == 1)
        #expect(buffs.items.count == 1)
    }

    @Test func adventureContextAlsoClears() throws {
        let collectibles = CollectiblesStore()
        let specs        = SpecialistsStore()
        collectibles.apply(.init(mapWidth: 1, mapHeight: 1,
                                 items: [.init(gridIndex: 0, x: 0, y: 0, assetName: "X")]))
        specs.apply(.init(items: [.init(uid: "1:1", uid1: 1, uid2: 1,
                                        specialistType: .geologist, subTypeId: 0,
                                        subTypeName: nil, name: "", isIdle: true, skills: [],
                                        collectedTime: nil, bonusTime: nil, taskEndTime: nil,
                                        taskActionType: nil, taskSubTaskId: nil)],
                          playerLevel: nil))
        let handler = ZoneContextHandler(
            offHomeStoresToClear: [specs, collectibles],
            logger: MockLogger())
        try handler.apply(payloadData: encode(["context": "adventure", "zoneId": NSNull()]))
        #expect(specs.items.isEmpty)
        #expect(collectibles.items.isEmpty)
    }

    @Test func homeContextDoesNotClear() throws {
        // Return-home transitions still fire ZONE_CONTEXT so Swift knows,
        // but the wipe should NOT re-run — the incoming home zone-load
        // response repopulates every store on its own.
        let collectibles = CollectiblesStore()
        let specs        = SpecialistsStore()
        collectibles.apply(.init(mapWidth: 1, mapHeight: 1,
                                 items: [.init(gridIndex: 0, x: 0, y: 0, assetName: "X")]))
        specs.apply(.init(items: [.init(uid: "1:1", uid1: 1, uid2: 1,
                                        specialistType: .geologist, subTypeId: 0,
                                        subTypeName: nil, name: "", isIdle: true, skills: [],
                                        collectedTime: nil, bonusTime: nil, taskEndTime: nil,
                                        taskActionType: nil, taskSubTaskId: nil)],
                          playerLevel: nil))
        let handler = ZoneContextHandler(
            offHomeStoresToClear: [specs, collectibles],
            logger: MockLogger())
        try handler.apply(payloadData: encode(["context": "home", "zoneId": 42]))
        #expect(specs.items.count == 1)
        #expect(collectibles.items.count == 1)
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
