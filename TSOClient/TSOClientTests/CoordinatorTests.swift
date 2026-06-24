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

// Each coordinator persists auto-loop state in UserDefaults; give every test
// a fresh suite so writes don't leak across tests or into the real domain.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test-\(UUID().uuidString)")!
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
            estimator: { _, _, _ in 60 })   // never fires within the test window
        coord.autoExplorerLoopEnabled = true
        await coord.lastAutoLoopTask?.value

        #expect(coord.pendingReDispatches["1:1"] != nil)
    }

    @Test func autoLoopReDispatchFiresAfterEstimateElapses() async {
        let store = SpecialistsStore()
        store.items = [makeItem(uid: "1:1", uid1: 1, uid2: 1, kind: .explorer)]
        let dispatcher = CapturingDispatcher()
        var calls = 0
        // First arming returns 50ms (long enough to outlast the sweep's
        // own 0-ns inter-call yield, short enough to keep the test snappy);
        // second call returns nil so the wake doesn't re-arm and we don't
        // loop indefinitely.
        let coord = SpecialistDispatchCoordinator(
            store: store, dispatcher: dispatcher,
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: isolatedDefaults(),
            estimator: { _, _, _ in
                calls += 1
                return calls == 1 ? 0.05 : nil
            })
        coord.autoReDispatchBuffer = 0
        coord.autoExplorerLoopTask = .treasureMedium
        coord.autoExplorerLoopEnabled = true
        await coord.lastAutoLoopTask?.value
        #expect(dispatcher.sent.count == 1)

        let wake = coord.pendingReDispatches["1:1"]
        await wake?.value

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
            estimator: { _, _, _ in 60 })
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

        await coord.runAutoGeologistLoop()?.value

        #expect(dispatcher.sent.isEmpty)
    }

    @Test func autoGeologistLoopFiresOnlyStoneColdSubtype() async {
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
        coord.autoGeologistLoopTask = .findStone
        coord.autoGeologistLoopEnabled = true

        await coord.lastAutoGeologistLoopTask?.value

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchSpecialistCommand
        #expect(cmd?.uid1 == 1 && cmd?.uid2 == 1)
        #expect(cmd?.actionType == 0 && cmd?.subTaskID == 0)
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
            estimator: { _, _, _ in 60 })  // wouldn't fire even if it ran
        coord.autoGeologistLoopEnabled = true
        await coord.lastAutoGeologistLoopTask?.value

        #expect(coord.pendingReDispatches.isEmpty)
    }

    @Test func autoGeologistLoopSettingsPersistAcrossInstances() {
        let defaults = isolatedDefaults()
        let first = SpecialistDispatchCoordinator(
            store: SpecialistsStore(), dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: defaults)
        first.autoGeologistLoopTask = .findMarble
        first.autoGeologistLoopEnabled = true

        let second = SpecialistDispatchCoordinator(
            store: SpecialistsStore(), dispatcher: CapturingDispatcher(),
            bulk: BulkDispatcher(interCallDelayNs: 0),
            logger: MockLogger(),
            defaults: defaults)

        #expect(second.autoGeologistLoopEnabled == true)
        #expect(second.autoGeologistLoopTask == .findMarble)
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

    @Test func buildingBuffsFilterUsesClassifier() {
        let buffs = BuffsStore(naming: .empty)
        let payload = InboundMessage.BuffsPayload(items: [
            .init(uid1: 1, uid2: 1, buffName: "ProductivityBuffLvl3",
                  resourceName: "", amount: 1, insertedAt: 0),
            .init(uid1: 2, uid2: 2, buffName: "HiredMilitary",
                  resourceName: "Recruit", amount: 1, insertedAt: 0),
        ])
        buffs.apply(payload)
        let classifier = BuffCategoryClassifier(
            buildingBuffs: .init(prefixes: ["ProductivityBuff"], exact: []))
        let coord = BuffDispatchCoordinator(
            buffsStore: buffs, buildingsStore: BuildingsStore(),
            dispatcher: CapturingDispatcher(),
            classifier: classifier, logger: MockLogger())

        let names = coord.buildingBuffs.map(\.buffName)
        #expect(names == ["ProductivityBuffLvl3"])
    }
}
