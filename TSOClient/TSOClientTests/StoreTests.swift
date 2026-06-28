import Testing
import Foundation
@testable import TSOClient

// ── SpecialistsStore ────────────────────────────────────────────────────────

private func specItem(uid: String = "1:1", uid1: Int = 1, uid2: Int = 1,
                      kind: SpecialistKind = .geologist,
                      subTypeId: Int = 0, isIdle: Bool = true,
                      collectedTime: Int? = nil,
                      taskActionType: Int? = nil,
                      taskSubTaskId: Int? = nil)
    -> InboundMessage.SpecialistsPayload.Item {
    .init(uid: uid, uid1: uid1, uid2: uid2,
          specialistType: kind, subTypeId: subTypeId,
          subTypeName: nil, name: "", isIdle: isIdle, skills: [],
          collectedTime: collectedTime, bonusTime: nil, taskEndTime: nil,
          taskActionType: taskActionType, taskSubTaskId: taskSubTaskId)
}

@Suite("SpecialistsStore")
struct SpecialistsStoreTests {

    @Test func applyCopiesPayloadIntoItems() {
        let store = SpecialistsStore()
        store.apply(.init(
            items: [specItem(uid: "7:8", uid1: 7, uid2: 8, kind: .explorer, subTypeId: 5)],
            playerLevel: 42
        ))
        #expect(store.items.count == 1)
        #expect(store.items[0].id == "7:8")
        #expect(store.items[0].specialistType == .explorer)
        #expect(store.playerLevel == 42)
    }

    @Test func applyWithoutPlayerLevelKeepsPrevious() {
        let store = SpecialistsStore()
        store.apply(.init(items: [], playerLevel: 30))
        store.apply(.init(items: [], playerLevel: nil))
        #expect(store.playerLevel == 30)
    }

    @Test func markDispatchedFlipsIdleAndSeedsTaskCode() {
        let store = SpecialistsStore()
        store.apply(.init(items: [specItem()], playerLevel: nil))

        store.markDispatched(uid: "1:1", actionType: 0, subTaskId: 5)

        let it = store.items[0]
        #expect(it.isIdle == false)
        #expect(it.taskActionType == 0)
        #expect(it.taskSubTaskId == 5)
    }

    @Test func markDispatchedForUnknownUidIsNoOp() {
        let store = SpecialistsStore()
        store.apply(.init(items: [specItem(uid: "1:1")], playerLevel: nil))
        store.markDispatched(uid: "9:9", actionType: 0, subTaskId: 0)
        #expect(store.items[0].isIdle == true)
    }

    @Test func clearWipesItemsAndLearnerState() {
        let kv = MockKeyValueStore()
        let learner = SpecialistDurationLearner(store: kv, logger: MockLogger())
        let store = SpecialistsStore(
            formatter: SpecialistDisplayFormatter(naming: .empty),
            learner: learner)
        store.apply(.init(items: [specItem()], playerLevel: nil))
        learner.markDispatched(uid: "1:1", subTypeId: 0, actionType: 0, subTaskId: 0)

        store.clear()
        #expect(store.items.isEmpty)
        #expect(learner.taskStartedAt.isEmpty)
    }
}

// ── BuildingsStore ──────────────────────────────────────────────────────────

private func buildingItem(grid: Int, skin: String,
                          uid1: Int = 0, uid2: Int = 0,
                          activeBuff: String? = nil)
    -> InboundMessage.BuildingsPayload.Item {
    .init(gridIndex: grid, skin: skin, uid1: uid1, uid2: uid2, activeBuff: activeBuff)
}

@Suite("BuildingsStore")
struct BuildingsStoreTests {

    @Test func applyComputesSkinBaseAndIndexesByBase() {
        let store = BuildingsStore()
        store.apply(.init(items: [
            buildingItem(grid: 10, skin: "Woodcutter_01"),
            buildingItem(grid: 20, skin: "Woodcutter_03"),
            buildingItem(grid: 30, skin: "Mason_01"),
        ]))

        #expect(store.items.count == 3)
        #expect(store.bySkinBase["Woodcutter"]?.map(\.gridIndex) == [10, 20])
        #expect(store.bySkinBase["Mason"]?.map(\.gridIndex) == [30])
        #expect(store.items[0].skinBase == "Woodcutter")
    }

    @Test func buildingsMatchingSortsAcrossMultipleBases() {
        let store = BuildingsStore()
        store.apply(.init(items: [
            buildingItem(grid: 50, skin: "Mason_01"),
            buildingItem(grid: 10, skin: "Woodcutter_01"),
            buildingItem(grid: 30, skin: "Mason_02"),
        ]))
        let matched = store.buildings(matchingSkinBases: ["Mason", "Woodcutter"])
        #expect(matched.map(\.gridIndex) == [10, 30, 50])
    }

    @Test func buildingsMatchingSingleBaseDoesNotResort() {
        // Single-base path returns the prebuilt sorted bucket as-is.
        let store = BuildingsStore()
        store.apply(.init(items: [
            buildingItem(grid: 20, skin: "Mason_01"),
            buildingItem(grid: 10, skin: "Mason_02"),
        ]))
        #expect(store.buildings(matchingSkinBases: ["Mason"]).map(\.gridIndex) == [10, 20])
    }

    @Test func clearEmptiesItemsAndIndex() {
        let store = BuildingsStore()
        store.apply(.init(items: [buildingItem(grid: 1, skin: "Mason_01")]))
        store.clear()
        #expect(store.items.isEmpty)
        #expect(store.bySkinBase.isEmpty)
    }

    @Test func initLoadsPersistedSkinBases() {
        let file = MockJSONFileStore()
        let persisted = BuildingsStore.Persisted(version: 1, skinBases: ["Mason", "Woodcutter"])
        file.files[BuildingsStore.persistenceFilename] =
            try! JSONEncoder().encode(persisted)

        let store = BuildingsStore(store: file, logger: MockLogger())
        #expect(store.seenSkinBases == ["Mason", "Woodcutter"])
    }

    @Test func applyAccumulatesAndPersistsNewSkinBases() {
        let file = MockJSONFileStore()
        let store = BuildingsStore(store: file, logger: MockLogger())

        store.apply(.init(items: [
            buildingItem(grid: 1, skin: "Mason_01"),
            buildingItem(grid: 2, skin: "Woodcutter_03"),
        ]))
        #expect(store.seenSkinBases == ["Mason", "Woodcutter"])
        #expect(file.writes.count == 1)

        let saved = file.load(BuildingsStore.Persisted.self,
                              from: BuildingsStore.persistenceFilename)
        #expect(saved?.skinBases == ["Mason", "Woodcutter"])

        // Re-apply same skinBases: no new write.
        store.apply(.init(items: [buildingItem(grid: 5, skin: "Mason_07")]))
        #expect(file.writes.count == 1)
        #expect(store.seenSkinBases == ["Mason", "Woodcutter"])

        // New skinBase: writes again, prior entries preserved.
        store.apply(.init(items: [buildingItem(grid: 9, skin: "BronzeMine_01")]))
        #expect(file.writes.count == 2)
        #expect(store.seenSkinBases == ["BronzeMine", "Mason", "Woodcutter"])
    }

    @Test func clearKeepsPersistedSkinBases() {
        // ZONE_LEFT wipes live items but the persisted catalog must survive
        // — that's the whole point of persisting it.
        let file = MockJSONFileStore()
        let store = BuildingsStore(store: file, logger: MockLogger())
        store.apply(.init(items: [buildingItem(grid: 1, skin: "Mason_01")]))

        store.clear()
        #expect(store.items.isEmpty)
        #expect(store.bySkinBase.isEmpty)
        #expect(store.seenSkinBases == ["Mason"])
    }
}

// ── BuffsStore ──────────────────────────────────────────────────────────────

private func buffItem(uid1: Int, uid2: Int, name: String,
                      amount: Int = 1, resource: String = "")
    -> InboundMessage.BuffsPayload.Item {
    .init(uid1: uid1, uid2: uid2, buffName: name,
          resourceName: resource, amount: amount, insertedAt: 0)
}

@Suite("BuffsStore")
struct BuffsStoreTests {

    @Test func applyIndexesByBuffNameAndKeepsFirstSeen() {
        let store = BuffsStore(naming: .empty)
        store.apply(.init(items: [
            buffItem(uid1: 1, uid2: 1, name: "ProductivityBuffLvl3", amount: 5),
            buffItem(uid1: 2, uid2: 2, name: "ProductivityBuffLvl3", amount: 7),
        ]))
        // First-seen wins for the dictionary entry, but totals add up.
        #expect(store.item(for: "ProductivityBuffLvl3")?.uid1 == 1)
        #expect(store.totalAmount(for: "ProductivityBuffLvl3") == 12)
    }

    @Test func applyUsesNamingRegistryForDisplayName() {
        let naming = NamingRegistry(
            specialistSubtypes: [:],
            buffs: ["ProductivityBuffLvl3": "Aunt Irma's Basket"],
            buildings: [:])
        let store = BuffsStore(naming: naming)
        store.apply(.init(items: [
            buffItem(uid1: 1, uid2: 1, name: "ProductivityBuffLvl3"),
        ]))
        #expect(store.item(for: "ProductivityBuffLvl3")?.displayName == "Aunt Irma's Basket")
    }

    @Test func uniqueTypesSortedByDisplayName() {
        let naming = NamingRegistry(
            specialistSubtypes: [:],
            buffs: ["B": "Apples", "A": "Zebras"],
            buildings: [:])
        let store = BuffsStore(naming: naming)
        store.apply(.init(items: [
            buffItem(uid1: 1, uid2: 1, name: "A"),
            buffItem(uid1: 2, uid2: 2, name: "B"),
        ]))
        #expect(store.uniqueTypes.map(\.buffName) == ["B", "A"])
    }

    @Test func versionBumpsOnApplyAndClear() {
        let store = BuffsStore(naming: .empty)
        let v0 = store.version
        store.apply(.init(items: []))
        let v1 = store.version
        store.clear()
        let v2 = store.version
        #expect(v1 != v0)
        #expect(v2 != v1)
    }

    @Test func clearEmptiesIndexesAndItems() {
        let store = BuffsStore(naming: .empty)
        store.apply(.init(items: [buffItem(uid1: 1, uid2: 1, name: "X")]))
        store.clear()
        #expect(store.items.isEmpty)
        #expect(store.byBuffName.isEmpty)
        #expect(store.totalAmountByName.isEmpty)
        #expect(store.uniqueTypes.isEmpty)
    }
}

// ── CollectiblesStore ───────────────────────────────────────────────────────

@Suite("CollectiblesStore")
struct CollectiblesStoreTests {

    @Test func applyPopulatesMapAndItems() {
        let store = CollectiblesStore()
        store.apply(.init(
            mapWidth: 89, mapHeight: 196,
            items: [
                .init(gridIndex: 100, x: 11, y: 1, assetName: "CollectibleHerbs"),
                .init(gridIndex: 200, x: 22, y: 2, assetName: "CollectibleFood"),
            ]
        ))
        #expect(store.mapWidth == 89)
        #expect(store.mapHeight == 196)
        #expect(store.items.map(\.id) == [100, 200])
        #expect(store.items[0].assetName == "CollectibleHerbs")
    }

    @Test func clearResetsMapAndItems() {
        let store = CollectiblesStore()
        store.apply(.init(mapWidth: 89, mapHeight: 196,
                          items: [.init(gridIndex: 1, x: 0, y: 0, assetName: "X")]))
        store.clear()
        #expect(store.items.isEmpty)
        #expect(store.mapWidth == 0)
        #expect(store.mapHeight == 0)
    }
}

// ── RecipientsStore ─────────────────────────────────────────────────────────

private func rosterItem(id: Int, name: String, level: Int = 1, online: Bool = false)
    -> InboundMessage.PlayerRosterPayload.Item {
    .init(id: id, username: name, level: level, online: online)
}

@Suite("RecipientsStore")
struct RecipientsStoreTests {

    @Test func friendsOnlyAreSortedCaseInsensitiveByName() {
        let store = RecipientsStore()
        store.applyFriends(.init(items: [
            rosterItem(id: 1, name: "charlie"),
            rosterItem(id: 2, name: "Alice"),
            rosterItem(id: 3, name: "bob"),
        ]))
        #expect(store.recipients.map(\.username) == ["Alice", "bob", "charlie"])
        #expect(store.recipients.allSatisfy { $0.sources == [.friend] })
    }

    @Test func friendAndGuildMergeIntoOneRecipientWithBothSources() {
        let store = RecipientsStore()
        store.applyFriends(.init(items: [rosterItem(id: 7, name: "Diana", level: 50, online: false)]))
        store.applyGuildMembers(.init(items: [rosterItem(id: 7, name: "Diana", level: 51, online: true)]))

        #expect(store.recipients.count == 1)
        let r = store.recipients[0]
        #expect(r.userID == 7)
        #expect(r.sources == [.friend, .guild])
        #expect(r.level == 51)
        #expect(r.online == true)
    }

    @Test func emptyUsernameSinksToBottom() {
        let store = RecipientsStore()
        store.applyFriends(.init(items: [
            rosterItem(id: 1, name: ""),
            rosterItem(id: 2, name: "Alice"),
            rosterItem(id: 3, name: ""),
        ]))
        let names = store.recipients.map(\.username)
        // Named entries first, blanks last (order among blanks isn't asserted).
        #expect(names.first == "Alice")
        #expect(names.last == "")
    }

    @Test func lookupByIdReturnsCanonicalEntry() {
        let store = RecipientsStore()
        store.applyFriends(.init(items: [rosterItem(id: 42, name: "Eve")]))
        #expect(store.recipient(id: 42)?.username == "Eve")
        #expect(store.recipient(id: 999) == nil)
    }

    @Test func reapplyReplacesPriorRoster() {
        let store = RecipientsStore()
        store.applyFriends(.init(items: [rosterItem(id: 1, name: "Old")]))
        store.applyFriends(.init(items: [rosterItem(id: 2, name: "New")]))
        #expect(store.recipients.map(\.userID) == [2])
    }
}
