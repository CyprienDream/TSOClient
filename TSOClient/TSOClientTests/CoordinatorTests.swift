import Testing
import Foundation
@testable import TSOClient

// Helpers for building test fixtures concisely.
private func makeItem(uid: String = "1:2", uid1: Int = 1, uid2: Int = 2,
                     kind: SpecialistKind = .geologist,
                     subTypeId: Int = 0,
                     isIdle: Bool = true,
                     skills: [SpecialistSkill] = []) -> SpecialistItem {
    SpecialistItem(
        id: uid, uid1: uid1, uid2: uid2,
        specialistType: kind,
        subTypeId: subTypeId,
        subTypeName: nil, name: "",
        isIdle: isIdle, skills: skills,
        collectedTime: nil, bonusTime: nil, taskEndTime: nil,
        taskActionType: nil, taskSubTaskId: nil
    )
}

// Each coordinator persists auto-loop state via a KeyValueStore; give every
// test a fresh in-memory store so writes don't leak across tests or into the
// real domain.
private func isolatedDefaults() -> KeyValueStore {
    MockKeyValueStore()
}

@Suite("SpecialistDispatchCoordinator")
struct SpecialistDispatchCoordinatorTests {

    @Test func dispatchOneSendsCommandAndFlipsToBusy() {
        let store = SpecialistsStore()
        let spec = makeItem()
        store.items = [spec]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())

        coord.dispatchOne(spec: spec, taskCode: TaskCode(actionType: 0, subTaskID: 3), targetGrid: 7)

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchSpecialistCommand
        #expect(cmd?.uid1 == 1)
        #expect(cmd?.uid2 == 2)
        #expect(cmd?.actionType == 0)
        #expect(cmd?.subTaskID == 3)
        #expect(cmd?.targetGrid == 7)

        // Optimistic flip in the store.
        #expect(store.items[0].isIdle == false)
        #expect(store.items[0].taskActionType == 0)
        #expect(store.items[0].taskSubTaskId == 3)
    }

    @Test func resolvedTaskCodeFallsBackToDefault() {
        let store = SpecialistsStore()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: CapturingDispatcher(),
            logger: MockLogger(),
            defaults: isolatedDefaults())
        let geo = makeItem(kind: .geologist)
        let exp = makeItem(uid: "3:4", uid1: 3, uid2: 4, kind: .explorer)

        #expect(coord.resolvedTaskCode(for: geo) == GeologistTask.findStone.taskCode)
        #expect(coord.resolvedTaskCode(for: exp) == ExplorerTask.treasureShort.taskCode)
    }

    @Test func applyBulkTaskPropagatesPerKind() {
        let store = SpecialistsStore()
        let geo = makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .geologist)
        let exp = makeItem(uid: "2:2", uid1: 2, uid2: 2, kind: .explorer)
        store.items = [geo, exp]
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: CapturingDispatcher(),
            logger: MockLogger(),
            defaults: isolatedDefaults())

        let geoCode = GeologistTask.findCoal.taskCode
        coord.applyBulkTask(geoCode, to: .geologist)

        #expect(coord.selectedTasks[geo.id] == geoCode)
        #expect(coord.selectedTasks[exp.id] == nil)
    }

    @Test func bulkDispatchSkillGatedTaskIsFiltered() async {
        // Explorer without skill 40 cannot run treasureColada (subTaskID=5,
        // actionType=1). The coordinator should skip it in the bulk plan.
        let store = SpecialistsStore()
        let exp = makeItem(uid: "9:9", uid1: 9, uid2: 9, kind: .explorer, skills: [])
        store.items = [exp]
        let dispatcher = CapturingDispatcher()
        let logger = MockLogger()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: logger,
            defaults: isolatedDefaults())
        coord.selectedTasks[exp.id] = ExplorerTask.treasureColada.taskCode

        await coord.bulkDispatch(idleSpecialists: [exp]).value

        #expect(dispatcher.sent.isEmpty)
        #expect(logger.messages.contains { $0.contains("firing 0 of 1") })
    }

    @Test func autoLoopOffIsNoOp() async {
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer)]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())

        await coord.runAutoExplorerLoop()?.value

        #expect(dispatcher.sent.isEmpty)
    }

    @Test func autoLoopFiresIdleExplorersAndSkipsBusy() async {
        let store = SpecialistsStore()
        let idleExp = makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer)
        let busyExp = makeItem(uid: "2:2", uid1: 2, uid2: 2, kind: .explorer, isIdle: false)
        let idleGeo = makeItem(uid: "3:3", uid1: 3, uid2: 3, kind: .geologist)
        store.items = [idleExp, busyExp, idleGeo]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())
        coord.autoExplorerLoopTask = .treasureMedium
        coord.autoExplorerLoopEnabled = true

        // Setter kicked off an immediate sweep; await its completion.
        await coord.lastAutoLoopTask?.value

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchSpecialistCommand
        #expect(cmd?.uid1 == 1 && cmd?.uid2 == 1)
        #expect(cmd?.actionType == 1 && cmd?.subTaskID == 1)
    }

    @Test func autoLoopSkipsSkillGatedTask() async {
        let store = SpecialistsStore()
        // No skill 40 → cannot run treasureColada.
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer, skills: [])]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())
        coord.autoExplorerLoopTask = .treasureColada
        coord.autoExplorerLoopEnabled = true

        await coord.runAutoExplorerLoop()?.value

        #expect(dispatcher.sent.isEmpty)
    }

    @Test func autoLoopSettingsPersistAcrossInstances() {
        let defaults = isolatedDefaults()
        let store = SpecialistsStore()

        let first = SpecialistDispatchCoordinator(
            store: store, dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: defaults)
        first.autoExplorerLoopTask = .adventureLong
        first.autoExplorerLoopEnabled = true

        let second = SpecialistDispatchCoordinator(
            store: SpecialistsStore(), dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: defaults)

        #expect(second.autoExplorerLoopEnabled == true)
        #expect(second.autoExplorerLoopTask == .adventureLong)
    }

    @Test func autoLoopArmsPerUidTimerWhenEnabled() async {
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer)]
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults(),
            estimator: FakeDurationEstimator { _, _, _ in 60 })   // never fires within the test window
        coord.autoExplorerLoopEnabled = true
        await coord.lastAutoLoopTask?.value

        #expect(coord.pendingReDispatches["1:1"] != nil)
    }

    @Test func reDispatchBodyInvokesDispatchOneWithStrategyTaskCode() async {
        // Deterministic substitute for the wall-clock-driven re-dispatch test:
        // exercises the wake body directly via `fireReDispatch`. The timer
        // wiring itself is covered by `autoLoopArmsPerUidTimerWhenEnabled`
        // (arm) and `autoLoopDisableCancelsPendingReDispatches` (cancel) —
        // we trust `Task.sleep` + body composition without sleeping on it.
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer)]
        let dispatcher = CapturingDispatcher()
        // Estimator returning nil keeps the initial sweep from arming any
        // wake, so dispatcher.sent.count == 1 is stable to observe.
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults(),
            estimator: FakeDurationEstimator { _, _, _ in nil })
        coord.autoExplorerLoopTask = .treasureMedium
        coord.autoExplorerLoopEnabled = true
        await coord.lastAutoLoopTask?.value
        #expect(dispatcher.sent.count == 1)

        await MainActor.run {
            coord.fireReDispatch(uid: "1:1", strategyId: "auto-loop-explorer")
        }

        #expect(dispatcher.sent.count == 2)
        let second = dispatcher.sent[1] as? DispatchSpecialistCommand
        #expect(second?.actionType == 1 && second?.subTaskID == 1)  // treasureMedium
        #expect(coord.pendingReDispatches.isEmpty)
    }

    @Test func autoLoopDisableCancelsPendingReDispatches() async {
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer)]
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults(),
            estimator: FakeDurationEstimator { _, _, _ in 60 })
        coord.autoExplorerLoopEnabled = true
        await coord.lastAutoLoopTask?.value
        #expect(coord.pendingReDispatches.count == 1)

        coord.autoExplorerLoopEnabled = false

        #expect(coord.pendingReDispatches.isEmpty)
    }

    @Test func autoGeologistLoopOffIsNoOp() async {
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1,
                                kind: .geologist, subTypeId: 35)]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())

        await coord.runAutoGeologistLoop(subTypeId: 35)?.value

        #expect(dispatcher.sent.isEmpty)
    }

    @Test func autoGeologistLoopFiresOnlyMatchingSubtype() async {
        let store = SpecialistsStore()
        let stoneCold = makeItem(uid: "1:1", uid1: 1, uid2: 1,
                                 kind: .geologist, subTypeId: 35)
        let jolly = makeItem(uid: "2:2", uid1: 2, uid2: 2,
                             kind: .geologist, subTypeId: 5)
        let busyStone = makeItem(uid: "3:3", uid1: 3, uid2: 3,
                                 kind: .geologist, subTypeId: 35, isIdle: false)
        store.items = [stoneCold, jolly, busyStone]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())
        coord.setGeologistLoopTask(.findStone, subTypeId: 35)
        coord.setGeologistLoopEnabled(true, subTypeId: 35)

        await coord.lastGeologistLoopTasks[35]?.value

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchSpecialistCommand
        #expect(cmd?.uid1 == 1 && cmd?.uid2 == 1)
        #expect(cmd?.actionType == 0 && cmd?.subTaskID == 0)
    }

    @Test func autoGeologistLoopRunsDiligentOnGoldIndependently() async {
        // Stone Cold + Diligent geologists with independent loops should
        // each dispatch to their own task on the same sweep — Stone Cold
        // to Granite, Diligent to Gold.
        let store = SpecialistsStore()
        store.playerLevel = 70   // unlock Granite (60+) and Gold (23+)
        let stoneCold = makeItem(uid: "1:1", uid1: 1, uid2: 1,
                                 kind: .geologist, subTypeId: 35)
        let diligent = makeItem(uid: "5:5", uid1: 5, uid2: 5,
                                kind: .geologist, subTypeId: 59)
        let jolly = makeItem(uid: "9:9", uid1: 9, uid2: 9,
                             kind: .geologist, subTypeId: 5)
        store.items = [stoneCold, diligent, jolly]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())
        coord.setGeologistLoopTask(.findGranite, subTypeId: 35)
        coord.setGeologistLoopEnabled(true, subTypeId: 35)
        coord.setGeologistLoopTask(.findGoldOre, subTypeId: 59)
        coord.setGeologistLoopEnabled(true, subTypeId: 59)

        await coord.lastGeologistLoopTasks[35]?.value
        await coord.lastGeologistLoopTasks[59]?.value

        let cmds = dispatcher.sent.compactMap { $0 as? DispatchSpecialistCommand }
        #expect(cmds.count == 2)
        let stoneCmd = cmds.first { $0.uid1 == 1 }
        let diligentCmd = cmds.first { $0.uid1 == 5 }
        #expect(stoneCmd?.actionType == 0 && stoneCmd?.subTaskID == GeologistTask.findGranite.rawValue)
        #expect(diligentCmd?.actionType == 0 && diligentCmd?.subTaskID == GeologistTask.findGoldOre.rawValue)
    }

    @Test func autoGeologistLoopArmsNoPerUidTimer() async {
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1,
                                kind: .geologist, subTypeId: 35)]
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults(),
            estimator: FakeDurationEstimator { _, _, _ in 60 })  // wouldn't fire even if it ran
        coord.setGeologistLoopEnabled(true, subTypeId: 35)
        await coord.lastGeologistLoopTasks[35]?.value

        #expect(coord.pendingReDispatches.isEmpty)
    }

    @Test func autoGeologistLoopSettingsPersistAcrossInstances() {
        let defaults = isolatedDefaults()
        let first = SpecialistDispatchCoordinator(
            store: SpecialistsStore(), dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: defaults)
        first.setGeologistLoopTask(.findMarble, subTypeId: 35)
        first.setGeologistLoopEnabled(true, subTypeId: 35)
        first.setGeologistLoopTask(.findGoldOre, subTypeId: 59)
        first.setGeologistLoopEnabled(true, subTypeId: 59)

        let second = SpecialistDispatchCoordinator(
            store: SpecialistsStore(), dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: defaults)

        #expect(second.geologistLoopState(subTypeId: 35).enabled == true)
        #expect(second.geologistLoopState(subTypeId: 35).task == .findMarble)
        #expect(second.geologistLoopState(subTypeId: 59).enabled == true)
        #expect(second.geologistLoopState(subTypeId: 59).task == .findGoldOre)
    }

    @Test func bulkDispatchAvailableTaskFires() async {
        let store = SpecialistsStore()
        let geo = makeItem(kind: .geologist)
        store.items = [geo]
        let dispatcher = CapturingDispatcher()
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults())

        await coord.bulkDispatch(idleSpecialists: [geo]).value

        #expect(dispatcher.sent.count == 1)
        #expect((dispatcher.sent[0] as? DispatchSpecialistCommand)?.actionType == 0)
    }
}

@Suite("BuffDispatchCoordinator")
struct BuffDispatchCoordinatorTests {

    private func makeBuildingsStore(grids: [Int]) -> BuildingsStore {
        let store = BuildingsStore()
        let payload = InboundMessage.BuildingsPayload(items: grids.map {
            .init(gridIndex: $0, skin: "WoodCutter_01", uid1: $0, uid2: 0, activeBuff: nil)
        })
        store.apply(payload)
        return store
    }

    private func makeBuffsStore(buffName: String,
                                buffUid1: Int = 100,
                                buffUid2: Int = 200) -> BuffsStore {
        let store = BuffsStore(naming: .empty)
        let payload = InboundMessage.BuffsPayload(items: [
            .init(uid1: buffUid1, uid2: buffUid2, buffName: buffName,
                  resourceName: "", amount: 50, insertedAt: 0)
        ])
        store.apply(payload)
        return store
    }

    @Test func selectMasterBuffPropagatesToEveryGroup() {
        let coord = BuffDispatchCoordinator(
            buffsStore: BuffsStore(naming: .empty),
            buildingsStore: BuildingsStore(),
            dispatcher: CapturingDispatcher(),
            classifier: .empty,
            logger: MockLogger())
        let cat1 = BuildingCategory(displayName: "Lumber", skinBases: ["WoodCutter"])
        let cat2 = BuildingCategory(displayName: "Stone",  skinBases: ["StoneMason"])
        let snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] = [
            (cat1, []), (cat2, [])
        ]

        coord.selectMasterBuff("ProductivityBuffLvl3", across: snapshot)

        #expect(coord.masterBuff == "ProductivityBuffLvl3")
        #expect(coord.selectedBuff[cat1.id] == "ProductivityBuffLvl3")
        #expect(coord.selectedBuff[cat2.id] == "ProductivityBuffLvl3")
    }

    @Test func buffAllSendsOnePerBuilding() async {
        let buffs = makeBuffsStore(buffName: "ProductivityBuffLvl3")
        let buildings = makeBuildingsStore(grids: [10, 20, 30])
        let dispatcher = CapturingDispatcher()
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: dispatcher,
            classifier: .empty,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger())

        let task = coord.buffAll(group: buildings.items, buffName: "ProductivityBuffLvl3")
        await task?.value

        #expect(dispatcher.sent.count == 3)
        let grids = dispatcher.sent.compactMap { ($0 as? DispatchBuffCommand)?.targetGrid }
        #expect(Set(grids) == Set([10, 20, 30]))
        for cmd in dispatcher.sent.compactMap({ $0 as? DispatchBuffCommand }) {
            #expect(cmd.buffUid1 == 100)
            #expect(cmd.buffUid2 == 200)
        }
    }

    @Test func buffAllWithUnknownBuffIsNoOp() async {
        let buffs = BuffsStore(naming: .empty)   // empty inventory
        let buildings = makeBuildingsStore(grids: [10])
        let dispatcher = CapturingDispatcher()
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: dispatcher,
            classifier: .empty,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger())

        let task = coord.buffAll(group: buildings.items, buffName: "DoesNotExist")
        await task?.value

        #expect(dispatcher.sent.isEmpty)
    }

    @Test func buffAllSkipsBuildingsAlreadyBuffed() async {
        // Grid 10 and 30 are unbuffed; grid 20 already carries an active buff.
        // Dispatch must hit only the unbuffed grids to avoid wasting stacks
        // against buildings the in-game UI would refuse to re-buff.
        let buffs = makeBuffsStore(buffName: "ProductivityBuffLvl3")
        let buildings = BuildingsStore()
        buildings.apply(InboundMessage.BuildingsPayload(items: [
            .init(gridIndex: 10, skin: "WoodCutter_01", uid1: 10, uid2: 0, activeBuff: nil),
            .init(gridIndex: 20, skin: "WoodCutter_01", uid1: 20, uid2: 0, activeBuff: "ProductivityBuffLvl3"),
            .init(gridIndex: 30, skin: "WoodCutter_01", uid1: 30, uid2: 0, activeBuff: nil),
        ]))
        let dispatcher = CapturingDispatcher()
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: dispatcher,
            classifier: .empty,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger())

        let task = coord.buffAll(group: buildings.items, buffName: "ProductivityBuffLvl3")
        await task?.value

        let grids = dispatcher.sent.compactMap { ($0 as? DispatchBuffCommand)?.targetGrid }
        #expect(Set(grids) == Set([10, 30]))
    }

    @Test func buffAllWhenEveryBuildingIsBuffedIsNoOp() async {
        let buffs = makeBuffsStore(buffName: "ProductivityBuffLvl3")
        let buildings = BuildingsStore()
        buildings.apply(InboundMessage.BuildingsPayload(items: [
            .init(gridIndex: 10, skin: "WoodCutter_01", uid1: 10, uid2: 0, activeBuff: "ProductivityBuffLvl3"),
            .init(gridIndex: 20, skin: "WoodCutter_01", uid1: 20, uid2: 0, activeBuff: "ProductivityBuffLvl3"),
        ]))
        let dispatcher = CapturingDispatcher()
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: dispatcher,
            classifier: .empty,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger())

        let task = coord.buffAll(group: buildings.items, buffName: "ProductivityBuffLvl3")
        await task?.value

        #expect(task == nil)
        #expect(dispatcher.sent.isEmpty)
    }

    @Test func buffAllGroupsSkipsBuffedAcrossCategories() async {
        // Two categories. Lumber has one buffed + one unbuffed; Stone has
        // both unbuffed. Master dispatch must touch the three unbuffed grids
        // and leave the already-buffed one alone.
        let buffs = makeBuffsStore(buffName: "ProductivityBuffLvl3")
        let buildings = BuildingsStore()
        buildings.apply(InboundMessage.BuildingsPayload(items: [
            .init(gridIndex: 10, skin: "WoodCutter_01", uid1: 10, uid2: 0, activeBuff: "ProductivityBuffLvl3"),
            .init(gridIndex: 11, skin: "WoodCutter_01", uid1: 11, uid2: 0, activeBuff: nil),
            .init(gridIndex: 20, skin: "Mason_01",      uid1: 20, uid2: 0, activeBuff: nil),
            .init(gridIndex: 21, skin: "Mason_01",      uid1: 21, uid2: 0, activeBuff: nil),
        ]))
        let categories = BuildingCategoryRegistry(categories: [
            BuildingCategory(displayName: "Lumber", skinBases: ["WoodCutter"], group: "Wood"),
            BuildingCategory(displayName: "Stone",  skinBases: ["Mason"],      group: "Masons"),
        ])
        let dispatcher = CapturingDispatcher()
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: dispatcher,
            classifier: .empty,
            categoryRegistry: categories,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger())
        let snapshot = coord.groups
        coord.selectMasterBuff("ProductivityBuffLvl3", across: snapshot)

        let task = coord.buffAllGroups(snapshot: snapshot)
        await task?.value

        let grids = dispatcher.sent.compactMap { ($0 as? DispatchBuffCommand)?.targetGrid }
        #expect(Set(grids) == Set([11, 20, 21]))
    }

    @Test func applyDefaultsResolvesSubgroupOrFallsBackToStaticDefault() {
        // Three categories exercising every resolution path:
        //   - Copper Mine has a subgroup entry "Aunt Irma's Basket" →
        //     resolves via inventory to "ProductivityBuffLvl3".
        //   - Iron Mine has a subgroup entry "" → opt-out, no default seeded.
        //   - Gold Mine has no subgroup entry → static fallback raw
        //     "ProductivityBuffLvl300".
        let naming = NamingRegistry(specialistSubtypes: [:], buffs: [
            "ProductivityBuffLvl3":   "Aunt Irma's Basket",
            "ProductivityBuffLvl300": "Aunt Irma's Feast",
        ], buildings: [:])
        let buffs = BuffsStore(naming: naming)
        buffs.apply(InboundMessage.BuffsPayload(items: [
            .init(uid1: 1, uid2: 1, buffName: "ProductivityBuffLvl3",
                  resourceName: "", amount: 10, insertedAt: 0),
            .init(uid1: 2, uid2: 2, buffName: "ProductivityBuffLvl300",
                  resourceName: "", amount: 10, insertedAt: 0),
        ]))
        let buildings = BuildingsStore()
        buildings.apply(InboundMessage.BuildingsPayload(items: [
            .init(gridIndex: 1, skin: "BronzeMine_01", uid1: 1, uid2: 0, activeBuff: nil),
            .init(gridIndex: 2, skin: "IronMine_01",   uid1: 2, uid2: 0, activeBuff: nil),
            .init(gridIndex: 3, skin: "GoldMine_01",   uid1: 3, uid2: 0, activeBuff: nil),
        ]))
        let categories = BuildingCategoryRegistry(categories: [
            BuildingCategory(displayName: "Copper Mine", skinBases: ["BronzeMine"], group: "Mines"),
            BuildingCategory(displayName: "Iron Mine",   skinBases: ["IronMine"],   group: "Mines"),
            BuildingCategory(displayName: "Gold Mine",   skinBases: ["GoldMine"],   group: "Mines"),
        ])
        let panelConfig = BuffPanelConfig(subgroups: [
            "Copper Mine": "Aunt Irma's Basket",
            "Iron Mine":   "",
        ])
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs, buildingsStore: buildings,
            dispatcher: CapturingDispatcher(),
            classifier: .empty,
            categoryRegistry: categories,
            panelConfig: panelConfig,
            logger: MockLogger())

        _ = coord.groups   // triggers applyDefaults

        // selectedBuff stores RAW names regardless of source.
        #expect(coord.selectedBuff["Copper Mine"] == "ProductivityBuffLvl3")
        #expect(coord.selectedBuff["Iron Mine"]   == nil)
        #expect(coord.selectedBuff["Gold Mine"]   == "ProductivityBuffLvl300")
    }

    @Test func ignoredSkinBaseIsDroppedFromUnmappedSnapshot() {
        // A building with a skin that matches the panel-config ignored list
        // should not appear in the coordinator's snapshot at all.
        let buildings = BuildingsStore()
        buildings.apply(InboundMessage.BuildingsPayload(items: [
            .init(gridIndex: 1, skin: "GreatHall_garrison_01", uid1: 1, uid2: 0, activeBuff: nil),
            .init(gridIndex: 2, skin: "Mason_01",              uid1: 2, uid2: 0, activeBuff: nil),
        ]))
        let categories = BuildingCategoryRegistry(categories: [
            BuildingCategory(displayName: "Stone Mason", skinBases: ["Mason"], group: "Masons"),
        ])
        let panelConfig = BuffPanelConfig(ignoredContains: ["garrison"])
        let coord = BuffDispatchCoordinator(
            buffsStore: BuffsStore(naming: .empty), buildingsStore: buildings,
            dispatcher: CapturingDispatcher(),
            classifier: .empty,
            categoryRegistry: categories,
            panelConfig: panelConfig,
            logger: MockLogger())

        let names = coord.groups.map(\.category.displayName)
        #expect(names == ["Stone Mason"])
    }

    // Shared fixture for filter tests: three categories across three groups,
    // chosen so name-based filters can target each one independently.
    private func makeFilterCoord() -> BuffDispatchCoordinator {
        let buildings = BuildingsStore()
        buildings.apply(InboundMessage.BuildingsPayload(items: [
            .init(gridIndex: 1, skin: "WoodCutter_01", uid1: 1, uid2: 0, activeBuff: nil),
            .init(gridIndex: 2, skin: "Mason_01",      uid1: 2, uid2: 0, activeBuff: nil),
            .init(gridIndex: 3, skin: "BronzeMine_01", uid1: 3, uid2: 0, activeBuff: nil),
        ]))
        let categories = BuildingCategoryRegistry(categories: [
            BuildingCategory(displayName: "Wood Cutter", skinBases: ["WoodCutter"], group: "Wood"),
            BuildingCategory(displayName: "Stone Mason", skinBases: ["Mason"],      group: "Masons"),
            BuildingCategory(displayName: "Copper Mine", skinBases: ["BronzeMine"], group: "Mines"),
        ])
        return BuffDispatchCoordinator(
            buffsStore: BuffsStore(naming: .empty),
            buildingsStore: buildings,
            dispatcher: CapturingDispatcher(),
            classifier: .empty,
            categoryRegistry: categories,
            logger: MockLogger())
    }

    @Test func filteredSnapshotEmptyQueryReturnsEverything() {
        let coord = makeFilterCoord()
        let all = coord.groupedSnapshot.flatMap { $0.items }.map(\.category.displayName)
        let filtered = coord.filteredGroupedSnapshot(matching: "")
            .flatMap { $0.items }.map(\.category.displayName)
        #expect(Set(filtered) == Set(all))
        #expect(filtered.count == all.count)
    }

    @Test func filteredSnapshotWhitespaceQueryReturnsEverything() {
        let coord = makeFilterCoord()
        let all = coord.groupedSnapshot.flatMap { $0.items }.map(\.category.displayName)
        let filtered = coord.filteredGroupedSnapshot(matching: "   \n\t  ")
            .flatMap { $0.items }.map(\.category.displayName)
        #expect(Set(filtered) == Set(all))
    }

    @Test func filteredSnapshotIsCaseInsensitiveSubstring() {
        let coord = makeFilterCoord()
        let names = coord.filteredGroupedSnapshot(matching: "mAsOn")
            .flatMap { $0.items }.map(\.category.displayName)
        #expect(names == ["Stone Mason"])
    }

    @Test func filteredSnapshotMatchesAcrossSections() {
        // "mine" appears in only one category ("Copper Mine"); the section
        // it belongs to should survive, and the other two should be dropped.
        let coord = makeFilterCoord()
        let sections = coord.filteredGroupedSnapshot(matching: "mine")
        #expect(sections.count == 1)
        #expect(sections.first?.items.map(\.category.displayName) == ["Copper Mine"])
    }

    @Test func filteredSnapshotNoMatchesReturnsEmpty() {
        let coord = makeFilterCoord()
        let sections = coord.filteredGroupedSnapshot(matching: "fishery")
        #expect(sections.isEmpty)
    }

    @Test func buildingBuffsFilterUsesClassifier() {
        let buffs = BuffsStore(naming: .empty)
        let payload = InboundMessage.BuffsPayload(items: [
            .init(uid1: 1, uid2: 1, buffName: "ProductivityBuffLvl3",
                  resourceName: "", amount: 1, insertedAt: 0),
            .init(uid1: 2, uid2: 2, buffName: "HiredMilitary",
                  resourceName: "Recruit", amount: 1, insertedAt: 0),
        ])
        buffs.apply(payload)
        let classifier = BuffCategoryClassifier(rules: [
            .buildingBuffs: .init(prefixes: ["ProductivityBuff"], exact: [])
        ])
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs, buildingsStore: BuildingsStore(),
            dispatcher: CapturingDispatcher(),
            classifier: classifier, logger: MockLogger())

        let names = coord.buildingBuffs.map(\.buffName)
        #expect(names == ["ProductivityBuffLvl3"])
    }
}
