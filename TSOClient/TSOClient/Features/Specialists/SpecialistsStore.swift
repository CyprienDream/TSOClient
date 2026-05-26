import Foundation
import Observation

@Observable
final class SpecialistsStore {
    var items: [SpecialistItem] = []
    var playerLevel: Int? = nil
    var serverTime: Double? = nil
    var serverTimeCapturedAt: Date? = nil
    // Wall-clock time we first observed each busy task. Server doesn't expose
    // task_start_time; collectedTime is total duration in ms (calibrated 2026-05-23
    // against in-game 5h2m remaining on a Bewitching Explorer w/ ct=163,485,578).
    // remaining = collectedTime/1000 - (now - taskStartedAt[uid]).
    // Exact for tasks we observed idle→busy; overestimates for tasks already busy at
    // app launch until the next observed transition.
    var taskStartedAt: [String: Date] = [:]

    struct SpecialistItem: Identifiable {
        let id: String          // "uid1:uid2"
        let uid1: Int
        let uid2: Int
        let specialistType: String      // "Explorer" | "Geologist" | "General" | "Unknown"
        let subTypeId: Int              // -1 if absent
        let subTypeName: String?        // CamelCase canonical name, e.g. "PirateExplorer"
        let name: String                // player's custom name (may be empty)
        let isIdle: Bool
        let skills: [Int]
        let collectedTime: Int?
        let bonusTime: Int?
        let taskEndTime: Double?

        // "PirateExplorer" → "Pirate Explorer". When no canonical name (e.g. Generals —
        // fedorovvl never enumerated General subtype IDs), fall back to the category
        // plus the int so different premium generals are still distinguishable.
        var displaySubtype: String {
            if let raw = subTypeName, !raw.isEmpty {
                var out = ""
                for (i, ch) in raw.enumerated() {
                    if i > 0 && ch.isUppercase { out.append(" ") }
                    out.append(ch)
                }
                return out
            }
            if subTypeId > 0 { return "\(specialistType) #\(subTypeId)" }
            return specialistType
        }

        // What to show as the primary label: player's custom name if set, otherwise subtype.
        var displayPrimary: String {
            name.isEmpty ? displaySubtype : name
        }

        // True when primary and secondary labels would be identical — caller can skip
        // rendering the duplicate.
        var hasDistinctSecondary: Bool {
            displayPrimary != displaySubtype
        }
    }

    func apply(_ payload: InboundMessage.SpecialistsPayload) {
        let now = Date()
        let nextUids = Set(payload.items.map { $0.uid })

        // Drop start times for specialists that are no longer busy (became idle, or
        // dropped from the list entirely).
        for uid in taskStartedAt.keys where !nextUids.contains(uid) {
            taskStartedAt.removeValue(forKey: uid)
        }

        // For each newly-busy spec we haven't timed yet, anchor now as task start.
        // Preserve existing anchors so countdown survives zone reloads.
        for item in payload.items {
            if !item.isIdle, taskStartedAt[item.uid] == nil {
                taskStartedAt[item.uid] = now
            }
            if item.isIdle {
                taskStartedAt.removeValue(forKey: item.uid)
            }
        }

        items = payload.items.map {
            SpecialistItem(
                id: $0.uid,
                uid1: $0.uid1,
                uid2: $0.uid2,
                specialistType: $0.specialistType,
                subTypeId: $0.subTypeId,
                subTypeName: $0.subTypeName,
                name: $0.name,
                isIdle: $0.isIdle,
                skills: $0.skills,
                collectedTime: $0.collectedTime,
                bonusTime: $0.bonusTime,
                taskEndTime: $0.taskEndTime
            )
        }
        if let lvl = payload.playerLevel { playerLevel = lvl }
        if let t = payload.serverTime {
            serverTime = t
            serverTimeCapturedAt = Date()
        }
    }

    // Optimistically flip the specialist to non-idle. Unity owns the in-game UI
    // and only repaints the icon/countdown bar on zone reload; flipping our row's
    // isIdle here gives immediate feedback in our panel until the next SPECIALISTS
    // message (zone reload) replaces it with authoritative server state.
    func markDispatched(uid: String) {
        guard let idx = items.firstIndex(where: { $0.id == uid }) else { return }
        let old = items[idx]
        items[idx] = SpecialistItem(
            id: old.id,
            uid1: old.uid1,
            uid2: old.uid2,
            specialistType: old.specialistType,
            subTypeId: old.subTypeId,
            subTypeName: old.subTypeName,
            name: old.name,
            isIdle: false,
            skills: old.skills,
            collectedTime: old.collectedTime,
            bonusTime: old.bonusTime,
            taskEndTime: old.taskEndTime
        )
        // Anchor the start time at dispatch — this is the only fresh transition we
        // can observe directly, so the countdown will be exact for this spec.
        taskStartedAt[uid] = Date()
    }

    func clear() { items = [] }
}
