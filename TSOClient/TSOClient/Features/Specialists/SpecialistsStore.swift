import Foundation
import Observation

@Observable
final class SpecialistsStore {
    var items: [SpecialistItem] = []
    var playerLevel: Int? = nil
    var serverTime: Double? = nil
    var serverTimeCapturedAt: Date? = nil

    // Prestigious Friend Buff (MultiplierBuffZone2_PremiumFriendBuff*). When
    // toggled on, every explorer/geologist duration estimate is multiplied
    // by ExplorerDurationRegistry.pfbMultiplier (0.8). Manual toggle for
    // now — we don't currently parse the active-buff vector from AMF.
    var pfbActive: Bool = false

    let formatter: SpecialistDisplayFormatter
    let learner: SpecialistDurationLearner

    // Convenience pass-throughs so existing call sites (panel, row) keep working.
    var taskStartedAt: [String: Date] { learner.taskStartedAt }
    var learnedDurations: [String: Int] { learner.learnedDurations }

    init(formatter: SpecialistDisplayFormatter = SpecialistDisplayFormatter(),
         learner: SpecialistDurationLearner = SpecialistDurationLearner()) {
        self.formatter = formatter
        self.learner = learner
    }

    func apply(_ payload: InboundMessage.SpecialistsPayload) {
        learner.process(payload: payload, formatter: formatter, pfbActive: pfbActive)

        items = payload.items.map {
            SpecialistItem(
                id:             $0.uid,
                uid1:           $0.uid1,
                uid2:           $0.uid2,
                specialistType: $0.specialistType,
                subTypeId:      $0.subTypeId,
                subTypeName:    $0.subTypeName,
                name:           $0.name,
                isIdle:         $0.isIdle,
                skills:         $0.skills,
                collectedTime:  $0.collectedTime,
                bonusTime:      $0.bonusTime,
                taskEndTime:    $0.taskEndTime,
                taskActionType: $0.taskActionType,
                taskSubTaskId:  $0.taskSubTaskId
            )
        }
        if let lvl = payload.playerLevel { playerLevel = lvl }
        if let t = payload.serverTime {
            serverTime = t
            serverTimeCapturedAt = Date()
        }
    }

    // Optimistic flip to non-idle. Seeds the busy snapshot immediately so the
    // duration learning loop has a start anchor even if the next zone load is
    // far in the future.
    func markDispatched(uid: String, actionType: Int, subTaskId: Int) {
        guard let idx = items.firstIndex(where: { $0.id == uid }) else { return }
        let old = items[idx]
        items[idx] = SpecialistItem(
            id:             old.id,
            uid1:           old.uid1,
            uid2:           old.uid2,
            specialistType: old.specialistType,
            subTypeId:      old.subTypeId,
            subTypeName:    old.subTypeName,
            name:           old.name,
            isIdle:         false,
            skills:         old.skills,
            collectedTime:  old.collectedTime,
            bonusTime:      old.bonusTime,
            taskEndTime:    old.taskEndTime,
            taskActionType: actionType,
            taskSubTaskId:  subTaskId
        )
        learner.markDispatched(
            uid: uid,
            subTypeId: old.subTypeId,
            actionType: actionType,
            subTaskId: subTaskId
        )
    }

    func clear() {
        items = []
        learner.clear()
    }
}
