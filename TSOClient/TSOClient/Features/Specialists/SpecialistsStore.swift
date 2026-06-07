import Foundation
import Observation

@Observable
final class SpecialistsStore {
    var items: [SpecialistItem] = []
    var playerLevel: Int? = nil
    var serverTime: Double? = nil
    var serverTimeCapturedAt: Date? = nil

    // Wall-clock time of actual task start, backtracked from ct on every zone load.
    // ct = elapsed ms since task start → taskStartedAt = now - ct/1000.
    var taskStartedAt: [String: Date] = [:]

    // Self-learning duration table. Populated when a specialist transitions busy→idle:
    // key = "subTypeId:actionType:subTaskId", value = total task duration in ms.
    // Persisted in UserDefaults so it survives app restarts.
    var learnedDurations: [String: Int] = [:] {
        didSet { UserDefaults.standard.set(learnedDurations, forKey: "tsoLearnedDurations") }
    }

    // Last-known task snapshot per uid, used to learn duration on completion.
    private struct BusySnapshot {
        let subTypeId: Int
        let actionType: Int
        let subTaskId: Int
        let lastCt: Int        // collectedTime at last observation
        let lastCtAt: Date     // wall-clock time of that observation
    }
    private var busySnapshots: [String: BusySnapshot] = [:]

    struct SpecialistItem: Identifiable {
        let id: String          // "uid1:uid2"
        let uid1: Int
        let uid2: Int
        let specialistType: SpecialistKind
        let subTypeId: Int              // -1 if absent
        let subTypeName: String?        // CamelCase canonical name, e.g. "PirateExplorer"
        let name: String                // player's custom name (may be empty)
        let isIdle: Bool
        let skills: [Int]
        let collectedTime: Int?
        let bonusTime: Int?
        let taskEndTime: Double?
        let taskActionType: Int?        // nil when idle
        let taskSubTaskId: Int?         // nil when idle

        var displaySubtype: String {
            if let raw = subTypeName, !raw.isEmpty {
                if raw == "Explorer" { return "Basic Explorer" }
                if raw == "General"  { return "Basic General" }
                return raw.camelCaseToWords
            }
            if subTypeId > 0 { return "\(specialistType.rawValue) #\(subTypeId)" }
            return specialistType.rawValue
        }

        var displayPrimary: String {
            name.isEmpty ? displaySubtype : name
        }

        var hasDistinctSecondary: Bool {
            displayPrimary != displaySubtype
        }

        // Key into the learned-duration table.
        var durationKey: String? {
            guard let at = taskActionType, let st = taskSubTaskId else { return nil }
            return "\(subTypeId):\(at):\(st)"
        }
    }

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "tsoLearnedDurations") as? [String: Int] {
            learnedDurations = saved
        }
    }

    func apply(_ payload: InboundMessage.SpecialistsPayload) {
        let now = Date()
        let nextUids = Set(payload.items.map { $0.uid })

        // Drop stale anchors for specialists no longer in the list.
        for uid in taskStartedAt.keys where !nextUids.contains(uid) {
            taskStartedAt.removeValue(forKey: uid)
        }

        for item in payload.items {
            if !item.isIdle {
                // Backtrack to actual task start using ct (elapsed ms).
                if let ct = item.collectedTime {
                    taskStartedAt[item.uid] = now.addingTimeInterval(-Double(ct) / 1000.0)
                } else if taskStartedAt[item.uid] == nil {
                    taskStartedAt[item.uid] = now
                }
                // Update snapshot for duration learning.
                if let ct = item.collectedTime,
                   let at = item.taskActionType,
                   let st = item.taskSubTaskId {
                    busySnapshots[item.uid] = BusySnapshot(
                        subTypeId: item.subTypeId,
                        actionType: at,
                        subTaskId: st,
                        lastCt: ct,
                        lastCtAt: now
                    )
                }
            } else {
                taskStartedAt.removeValue(forKey: item.uid)
                // Specialist just completed their task — record approximate total duration.
                if let snap = busySnapshots[item.uid] {
                    let extraMs = Int(now.timeIntervalSince(snap.lastCtAt) * 1000)
                    let approxTotal = snap.lastCt + extraMs
                    let key = "\(snap.subTypeId):\(snap.actionType):\(snap.subTaskId)"
                    // Keep the most recent observation (last completion is most accurate).
                    learnedDurations[key] = approxTotal
                }
                busySnapshots.removeValue(forKey: item.uid)
            }
        }
        // Drop snapshots for specialists that left the list entirely.
        for uid in busySnapshots.keys where !nextUids.contains(uid) {
            busySnapshots.removeValue(forKey: uid)
        }

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

    // Optimistic flip to non-idle. Seeds the busy snapshot immediately so the duration
    // learning loop has a start anchor even if the next zone load is far in the future.
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
        let now = Date()
        taskStartedAt[uid] = now
        busySnapshots[uid] = BusySnapshot(
            subTypeId: old.subTypeId,
            actionType: actionType,
            subTaskId: subTaskId,
            lastCt: 0,
            lastCtAt: now
        )
    }

    func clear() { items = [] }
}
