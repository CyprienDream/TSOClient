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

@Suite("BuffDurationLearner")
struct BuffDurationLearnerTests {

    private func buildings(expired: Bool,
                           uid: Int = 10,
                           skin: String = "WoodCutter_01",
                           mode: Int? = nil)
        -> [BuildingsStore.BuildingItem] {
        let store = BuildingsStore()
        store.apply(.init(items: [
            .init(gridIndex: uid, skin: skin, uid1: uid, uid2: 0,
                  activeBuff: expired ? nil : "ProductivityBuffLvl3",
                  activeBuffApplianceMode: expired ? nil : mode,
                  paused: false)
        ]))
        return store.items
    }

    @Test func learnsDurationFromDispatchToExpiry() {
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())
        learner.recordDispatch(uidKey: "10:0", buffName: "ProductivityBuffLvl3",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: buildings(expired: false),
                        now: Date(timeIntervalSince1970: 100))
        #expect(learner.learnedDuration(for: "ProductivityBuffLvl3",
                                        applianceMode: nil) == nil)

        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 300))
        #expect(learner.learnedDuration(for: "ProductivityBuffLvl3",
                                        applianceMode: nil) == 300)
    }

    @Test func keepsMaxAcrossObservations() {
        // Later samples that are shorter must not shrink the learned value —
        // firing too early would waste buff stacks. Taking the max biases us
        // toward firing slightly late, which the zone-load sweep still covers.
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 500))
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: nil) == 500)

        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 1000))
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 1300))
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: nil) == 500)
    }

    @Test func rejectsOutOfRangeSamples() {
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 5))
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: nil) == nil)

        learner.recordDispatch(uidKey: "11:0", buffName: "Lvl300",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: buildings(expired: true, uid: 11),
                        now: Date(timeIntervalSince1970: 400 * 3600))
        #expect(learner.learnedDuration(for: "Lvl300", applianceMode: nil) == nil)
    }

    @Test func missingBuildingClearsTrackingWithoutLearning() {
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: [], now: Date(timeIntervalSince1970: 300))
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: nil) == nil)
    }

    @Test func persistsAcrossInstances() {
        let kv = MockKeyValueStore()
        let first = BuffDurationLearner(defaults: kv, logger: MockLogger())
        first.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                             at: Date(timeIntervalSince1970: 0))
        first.observe(buildings: buildings(expired: true),
                      now: Date(timeIntervalSince1970: 400))
        #expect(first.learnedDuration(for: "Lvl3", applianceMode: nil) == 400)

        let second = BuffDurationLearner(defaults: kv, logger: MockLogger())
        #expect(second.learnedDuration(for: "Lvl3", applianceMode: nil) == 400)
    }

    // --- mode-keyed learning ---------------------------------------------
    // The same buff gets different durations server-side depending on the
    // applianceMode the server assigns (self vs friend vs PFB-boosted). The
    // learner must bucket samples by mode so e.g. a 12h friend-applied
    // duration doesn't average with a 24h self-applied duration.

    @Test func latchesModeFromInterimObservation() {
        // Observing the building while it's still buffed captures the mode;
        // the subsequent expiry records against (name, mode) not (name, *).
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 0))
        // Interim: buff still active, mode visible
        learner.observe(buildings: buildings(expired: false, mode: 1),
                        now: Date(timeIntervalSince1970: 100))
        // Expiry
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 500))

        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: 1) == 500)
        // Mode-specific lookup for a different mode falls through to the
        // max across known modes (still 500 in this one-mode case).
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: 9) == 500)
    }

    @Test func modesAreBucketedSeparately() {
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())

        // Mode 0: 600 seconds
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: buildings(expired: false, mode: 0),
                        now: Date(timeIntervalSince1970: 60))
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 600))

        // Mode 1: 300 seconds (shorter — friend-applied, say)
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 1000))
        learner.observe(buildings: buildings(expired: false, mode: 1),
                        now: Date(timeIntervalSince1970: 1060))
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 1300))

        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: 0) == 600)
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: 1) == 300)
        // Unknown mode → max across buckets (600).
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: nil) == 600)
    }

    @Test func missingModeFallsIntoAnyModeBucket() {
        // No interim observation → mode never latched → learn goes to `|*`.
        let kv = MockKeyValueStore()
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())
        learner.recordDispatch(uidKey: "10:0", buffName: "Lvl3",
                               at: Date(timeIntervalSince1970: 0))
        learner.observe(buildings: buildings(expired: true),
                        now: Date(timeIntervalSince1970: 400))

        // Mode-specific lookup misses and cascades to any-mode (400).
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: 0) == 400)
        #expect(learner.learnedDuration(for: "Lvl3", applianceMode: nil) == 400)
    }

    @Test func legacyKeyIsMigratedIntoAnyModeBucket() {
        // Simulate a pre-v2 persistence snapshot — v1 stored at
        // "buffs.learnedDurations". The learner must surface those values
        // via the any-mode fallback on first instantiation.
        let kv = MockKeyValueStore()
        kv.set(["Lvl3": TimeInterval(1200), "Lvl10": TimeInterval(3600)],
               forKey: "buffs.learnedDurations")
        let learner = BuffDurationLearner(defaults: kv, logger: MockLogger())

        #expect(learner.learnedDuration(for: "Lvl3",  applianceMode: nil) == 1200)
        #expect(learner.learnedDuration(for: "Lvl10", applianceMode: nil) == 3600)
        // Mode-specific lookup also cascades through the any-mode bucket.
        #expect(learner.learnedDuration(for: "Lvl3",  applianceMode: 0)   == 1200)
    }
}
