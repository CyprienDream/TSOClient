import Testing
import Foundation
@testable import TSOClient

// Helper to build a SpecialistsPayload.Item with a few overridable fields.
private func payloadItem(uid: String = "7:8", uid1: Int = 7, uid2: Int = 8,
                         kind: SpecialistKind = .geologist,
                         subTypeId: Int = 0,
                         subTypeName: String? = nil,
                         name: String = "",
                         isIdle: Bool = false,
                         skills: [SpecialistSkill] = [],
                         collectedTime: Int? = 1000,
                         taskActionType: Int? = 0,
                         taskSubTaskId: Int? = 0)
                         -> InboundMessage.SpecialistsPayload.Item {
    .init(uid: uid, uid1: uid1, uid2: uid2,
          specialistType: kind, subTypeId: subTypeId, subTypeName: subTypeName,
          name: name, isIdle: isIdle, skills: skills,
          collectedTime: collectedTime, bonusTime: nil, taskEndTime: nil,
          taskActionType: taskActionType, taskSubTaskId: taskSubTaskId)
}

@Suite("SpecialistDurationLearner")
struct SpecialistDurationLearnerTests {

    @Test func markDispatchedSeedsAnchor() {
        let learner = SpecialistDurationLearner(
            store: MockKeyValueStore(), logger: MockLogger())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        learner.markDispatched(uid: "7:8", subTypeId: 1, actionType: 0, subTaskId: 5, now: now)

        #expect(learner.taskStartedAt["7:8"] == now)
    }

    @Test func busyToIdleRecordsObservedDuration() {
        let kv = MockKeyValueStore()
        let learner = SpecialistDurationLearner(
            store: kv, logger: MockLogger())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10)   // 10s later

        // Busy at t0 with ct=1000 ms (bonus 100 default → 1.0s elapsed).
        let busy = InboundMessage.SpecialistsPayload(
            items: [payloadItem(collectedTime: 1000, taskActionType: 0, taskSubTaskId: 0)],
            playerLevel: nil)
        learner.process(payload: busy, formatter: SpecialistDisplayFormatter(naming: .empty), now: t0)

        // Idle at t1.
        let idle = InboundMessage.SpecialistsPayload(
            items: [payloadItem(isIdle: true, collectedTime: nil,
                                taskActionType: nil, taskSubTaskId: nil)],
            playerLevel: nil)
        learner.process(payload: idle, formatter: SpecialistDisplayFormatter(naming: .empty), now: t1)

        // Anchor at t0 was backtracked to (t0 - 1s); observed total at t1 = 11s ≈ 11000 ms.
        let key = "0:0:0"  // subTypeId:actionType:subTaskId
        let observed = learner.learnedDurations[key] ?? -1
        #expect(observed >= 10_900 && observed <= 11_100)
        #expect(learner.taskStartedAt["7:8"] == nil)
    }

    @Test func learnedDurationsPersistedToKeyValueStore() {
        let kv = MockKeyValueStore()
        let learner = SpecialistDurationLearner(
            store: kv, logger: MockLogger(), persistKey: "tsoLearnedDurations")
        let t0 = Date()

        let busy = InboundMessage.SpecialistsPayload(
            items: [payloadItem(collectedTime: 1000, taskActionType: 0, taskSubTaskId: 0)],
            playerLevel: nil)
        let idle = InboundMessage.SpecialistsPayload(
            items: [payloadItem(isIdle: true, collectedTime: nil,
                                taskActionType: nil, taskSubTaskId: nil)],
            playerLevel: nil)

        learner.process(payload: busy, formatter: SpecialistDisplayFormatter(naming: .empty), now: t0)
        learner.process(payload: idle, formatter: SpecialistDisplayFormatter(naming: .empty),
                        now: t0.addingTimeInterval(5))

        #expect(kv.setHistory.contains { $0.key == "tsoLearnedDurations" })
        let saved = kv.dictionary(forKey: "tsoLearnedDurations") as? [String: Int]
        #expect(saved?["0:0:0"] != nil)
    }

    @Test func staleAnchorsDroppedWhenUIDsLeave() {
        let learner = SpecialistDurationLearner(
            store: MockKeyValueStore(), logger: MockLogger())
        let busy = InboundMessage.SpecialistsPayload(
            items: [payloadItem()], playerLevel: nil)
        learner.process(payload: busy, formatter: SpecialistDisplayFormatter(naming: .empty))
        #expect(learner.taskStartedAt["7:8"] != nil)

        let empty = InboundMessage.SpecialistsPayload(items: [], playerLevel: nil)
        learner.process(payload: empty, formatter: SpecialistDisplayFormatter(naming: .empty))

        #expect(learner.taskStartedAt.isEmpty)
    }

    @Test func initLoadsPreviouslyPersistedDurations() {
        let kv = MockKeyValueStore()
        kv.set(["42:1:3": 9_876], forKey: "tsoLearnedDurations")

        let learner = SpecialistDurationLearner(store: kv, logger: MockLogger())
        #expect(learner.learnedDurations["42:1:3"] == 9_876)
    }

    @Test func backtrackAnchorsBasedOnCollectedTime() {
        let learner = SpecialistDurationLearner(
            store: MockKeyValueStore(), logger: MockLogger())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // ct=5000 ms with default bonus 100 → 5s elapsed.
        let busy = InboundMessage.SpecialistsPayload(
            items: [payloadItem(collectedTime: 5000)],
            playerLevel: nil)
        learner.process(payload: busy, formatter: SpecialistDisplayFormatter(naming: .empty), now: now)

        let anchor = learner.taskStartedAt["7:8"]
        #expect(anchor?.timeIntervalSince1970 == now.addingTimeInterval(-5).timeIntervalSince1970)
    }

    @Test func busyLogEmittedForGeologist() {
        let logger = MockLogger()
        let learner = SpecialistDurationLearner(
            store: MockKeyValueStore(), logger: logger)
        let busy = InboundMessage.SpecialistsPayload(
            items: [payloadItem(kind: .geologist, collectedTime: 1000,
                                taskActionType: 0, taskSubTaskId: 0)],
            playerLevel: nil)
        learner.process(payload: busy, formatter: SpecialistDisplayFormatter(naming: .empty))

        #expect(logger.messages.contains { $0.contains("[GeologistDuration] busy") })
    }

    @Test func noLogForGeneralKind() {
        let logger = MockLogger()
        let learner = SpecialistDurationLearner(
            store: MockKeyValueStore(), logger: logger)
        let busy = InboundMessage.SpecialistsPayload(
            items: [payloadItem(kind: .general, taskActionType: 12, taskSubTaskId: 0)],
            playerLevel: nil)
        learner.process(payload: busy, formatter: SpecialistDisplayFormatter(naming: .empty))

        #expect(logger.messages.isEmpty)
    }

    @Test func clearWipesAllState() {
        let learner = SpecialistDurationLearner(
            store: MockKeyValueStore(), logger: MockLogger())
        learner.markDispatched(uid: "1:1", subTypeId: 0, actionType: 0, subTaskId: 0)
        #expect(!learner.taskStartedAt.isEmpty)

        learner.clear()
        #expect(learner.taskStartedAt.isEmpty)
    }
}

@Suite("SpecialistDisplayFormatter")
struct SpecialistDisplayFormatterTests {

    private let naming = NamingRegistry(
        specialistSubtypes: ["Soccer2019Explorer": "Adventurous Explorer"],
        buffs: [:], buildings: [:])

    private func item(name: String = "", subTypeName: String? = "PirateExplorer",
                      subTypeId: Int = 5,
                      kind: SpecialistKind = .explorer) -> SpecialistItem {
        SpecialistItem(id: "1:1", uid1: 1, uid2: 1,
                       specialistType: kind, subTypeId: subTypeId,
                       subTypeName: subTypeName, name: name,
                       isIdle: true, skills: [],
                       collectedTime: nil, bonusTime: nil, taskEndTime: nil,
                       taskActionType: nil, taskSubTaskId: nil)
    }

    @Test func overrideWinsOverCamelCaseSplit() {
        let f = SpecialistDisplayFormatter(naming: naming)
        let i = item(subTypeName: "Soccer2019Explorer")
        #expect(f.displaySubtype(for: i) == "Adventurous Explorer")
    }

    @Test func camelCaseFallbackWhenNoOverride() {
        let f = SpecialistDisplayFormatter(naming: naming)
        #expect(f.displaySubtype(for: item(subTypeName: "PirateExplorer")) == "Pirate Explorer")
    }

    @Test func emptySubTypeNameUsesKindAndId() {
        let f = SpecialistDisplayFormatter(naming: naming)
        #expect(f.displaySubtype(for: item(subTypeName: "", subTypeId: 5)) == "Explorer #5")
        #expect(f.displaySubtype(for: item(subTypeName: nil, subTypeId: 5)) == "Explorer #5")
    }

    @Test func emptySubTypeNameAndZeroIdJustUsesKind() {
        let f = SpecialistDisplayFormatter(naming: naming)
        #expect(f.displaySubtype(for: item(subTypeName: nil, subTypeId: -1)) == "Explorer")
    }

    @Test func displayPrimaryFallsBackToSubtypeWhenNameEmpty() {
        let f = SpecialistDisplayFormatter(naming: naming)
        let blank = item(name: "", subTypeName: "PirateExplorer")
        let named = item(name: "Jack", subTypeName: "PirateExplorer")
        #expect(f.displayPrimary(for: blank) == "Pirate Explorer")
        #expect(f.displayPrimary(for: named) == "Jack")
    }

    @Test func hasDistinctSecondaryWhenNameIsCustom() {
        let f = SpecialistDisplayFormatter(naming: naming)
        #expect(f.hasDistinctSecondary(for: item(name: "Jack")))
        #expect(!f.hasDistinctSecondary(for: item(name: "")))
    }

    @Test func compactDisplayNameForLogLine() {
        let f = SpecialistDisplayFormatter(naming: naming)
        // payload item shape needed by the formatter
        let blank = InboundMessage.SpecialistsPayload.Item(
            uid: "1:1", uid1: 1, uid2: 1, specialistType: .explorer,
            subTypeId: 5, subTypeName: "PirateExplorer", name: "",
            isIdle: false, skills: [],
            collectedTime: nil, bonusTime: nil, taskEndTime: nil,
            taskActionType: nil, taskSubTaskId: nil)
        let named = InboundMessage.SpecialistsPayload.Item(
            uid: "1:1", uid1: 1, uid2: 1, specialistType: .explorer,
            subTypeId: 5, subTypeName: "PirateExplorer", name: "Jack",
            isIdle: false, skills: [],
            collectedTime: nil, bonusTime: nil, taskEndTime: nil,
            taskActionType: nil, taskSubTaskId: nil)
        #expect(f.compactDisplayName(forPayloadItem: blank) == "Pirate Explorer")
        #expect(f.compactDisplayName(forPayloadItem: named) == "Jack (Pirate Explorer)")
    }
}
