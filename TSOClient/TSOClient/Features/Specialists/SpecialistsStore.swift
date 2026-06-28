import Foundation
import Observation

@Observable
final class SpecialistsStore {
    var items: [SpecialistItem] = []
    var playerLevel: Int? = nil

    // Prestigious Friend Buff (MultiplierBuffZone2_PremiumFriendBuff*). When
    // active, every explorer/geologist duration estimate is multiplied by
    // ExplorerDurationRegistry.pfbMultiplier (0.8). Auto-detected from
    // dZoneVO.zoneBuffs by PlayerBuffsHandler; the panel toggle is a
    // manual override that the next inbound PLAYER_BUFFS payload reasserts.
    var pfbActive: Bool = false

    let formatter: SpecialistDisplayFormatter
    let learner: SpecialistDurationLearner

    // Hash of the last applied payload — when the game re-sends an identical
    // specialists list (common when everyone's idle) we skip the learner pass,
    // the SpecialistItem.map alloc, and the differ walk.
    private var lastFingerprint: Int?

    init(formatter: SpecialistDisplayFormatter = SpecialistDisplayFormatter(),
         learner: SpecialistDurationLearner = SpecialistDurationLearner()) {
        self.formatter = formatter
        self.learner = learner
    }

    func apply(_ payload: InboundMessage.SpecialistsPayload) {
        let fingerprint = Self.fingerprint(of: payload)
        if fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint

        learner.process(payload: payload, formatter: formatter, pfbActive: pfbActive)

        let next = payload.items.map {
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
        SpecialistsDiffer.apply(next: next, to: &items)
        if let lvl = payload.playerLevel { playerLevel = lvl }
    }

    // Optimistic flip to non-idle. Seeds the busy snapshot immediately so the
    // duration learning loop has a start anchor even if the next zone load is
    // far in the future.
    func markDispatched(uid: String, actionType: Int, subTaskId: Int) {
        guard let idx = items.firstIndex(where: { $0.id == uid }) else { return }
        // Invalidate the apply-fingerprint so the next SPECIALISTS payload
        // is re-processed even if its on-wire bytes happen to match the
        // last one (e.g. game re-sends pre-dispatch state before catching up).
        lastFingerprint = nil
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
        lastFingerprint = nil
        learner.clear()
    }

    private static func fingerprint(of payload: InboundMessage.SpecialistsPayload) -> Int {
        var hasher = Hasher()
        hasher.combine(payload.playerLevel)
        hasher.combine(payload.items.count)
        for it in payload.items {
            hasher.combine(it.uid)
            hasher.combine(it.subTypeId)
            hasher.combine(it.isIdle)
            hasher.combine(it.taskActionType)
            hasher.combine(it.taskSubTaskId)
            hasher.combine(it.taskEndTime)
            hasher.combine(it.collectedTime)
            for sk in it.skills {
                hasher.combine(sk.id)
                hasher.combine(sk.level)
            }
        }
        return hasher.finalize()
    }
}
