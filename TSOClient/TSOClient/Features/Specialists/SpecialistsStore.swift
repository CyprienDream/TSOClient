import Foundation
import Observation

@Observable
final class SpecialistsStore {
    var items: [SpecialistItem] = []
    var playerLevel: Int? = nil
    var serverTime: Double? = nil
    var serverTimeCapturedAt: Date? = nil

    // Wall-clock time of actual task start, backtracked from ct on every zone load.
    // ct is in base-time-equivalent milliseconds (advances at bonus/100 × real time, so a
    // 3× subtype's ct ticks 3× wall clock). Real elapsed seconds = ct/1000 × 100/bonus.
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

    struct SpecialistSkill: Decodable, Hashable {
        let id: Int
        let level: Int
    }

    struct SpecialistItem: Identifiable {
        let id: String          // "uid1:uid2"
        let uid1: Int
        let uid2: Int
        let specialistType: SpecialistKind
        let subTypeId: Int              // -1 if absent
        let subTypeName: String?        // CamelCase canonical name, e.g. "PirateExplorer"
        let name: String                // player's custom name (may be empty)
        let isIdle: Bool
        let skills: [SpecialistSkill]
        let collectedTime: Int?
        let bonusTime: Int?
        let taskEndTime: Double?
        let taskActionType: Int?        // nil when idle
        let taskSubTaskId: Int?         // nil when idle

        // Manual overrides for subtype labels that don't read well as a plain
        // CamelCase split — e.g. the "Soccer2019" promo explorer is shown
        // in-game as "Adventurous".
        static let subtypeDisplayOverrides: [String: String] = [
            "Explorer":                     "Basic Explorer",
            "General":                      "Basic General",
            "Soccer2019Explorer":           "Adventurous Explorer",
            "FastLuckyExplorer":            "Lucky Explorer",
            "EasterExplorer":               "Experienced Explorer",
            "EmphaticExplorer":             "Emphatic Explorer",
            "MasterExplorer":               "Savage Scout",
            "SmugglerGeneral":              "Smuggler",
            "MasterOfMartialArtsGeneral":   "Master of Martial Arts",
        ]

        var displaySubtype: String {
            if let raw = subTypeName, !raw.isEmpty {
                if let override = Self.subtypeDisplayOverrides[raw] { return override }
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

    private static func logPrefix(for kind: SpecialistKind) -> String? {
        switch kind {
        case .explorer:  return "ExplorerDuration"
        case .geologist: return "GeologistDuration"
        case .general, .unknown: return nil
        }
    }

    private static func displayName(for item: InboundMessage.SpecialistsPayload.Item) -> String {
        let raw = item.subTypeName ?? ""
        let subtype: String
        if let override = SpecialistItem.subtypeDisplayOverrides[raw] { subtype = override }
        else if !raw.isEmpty { subtype = raw.camelCaseToWords }
        else { subtype = "\(item.specialistType.rawValue) #\(item.subTypeId)" }
        return item.name.isEmpty ? subtype : "\(item.name) (\(subtype))"
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
                // Backtrack to actual task start. ct is base-time-equivalent ms; real
                // elapsed seconds = ct/1000 × 100/bonus. Non-explorer subtypes have no
                // bonus in the registry — default to 100 (no scaling) which keeps the
                // current geologist/general behavior.
                let bonus = ExplorerDurationRegistry.timeBonus[item.subTypeId] ?? 100
                if let ct = item.collectedTime {
                    let realElapsedSec = Double(ct) / 1000.0 * 100.0 / Double(bonus)
                    taskStartedAt[item.uid] = now.addingTimeInterval(-realElapsedSec)
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
                    // Per-specialist busy log so the user can cross-reference predictions
                    // (or just skill IDs for kinds we don't have a registry for yet)
                    // against the in-game UI without waiting for task completion.
                    if let prefix = Self.logPrefix(for: item.specialistType) {
                        let code = TaskCode(actionType: at, subTaskID: st)
                        let skillStr = item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
                        let realElapsedS = Double(ct) / 1000.0 * 100.0 / Double(bonus)
                        if let predicted = ExplorerDurationRegistry.estimate(
                            task: code, subTypeId: item.subTypeId, skills: item.skills) {
                            let remainingS = max(0, predicted - realElapsedS)
                            print("[\(prefix)] busy \"\(Self.displayName(for: item))\" uid=\(item.uid) type=\(item.subTypeId) " +
                                  "task=\(at),\(st) skills=[\(skillStr)] " +
                                  "predicted=\(Int(predicted))s elapsed=\(Int(realElapsedS))s " +
                                  "remaining=\(Int(remainingS))s")
                        } else {
                            print("[\(prefix)] busy \"\(Self.displayName(for: item))\" uid=\(item.uid) type=\(item.subTypeId) " +
                                  "task=\(at),\(st) skills=[\(skillStr)] elapsed=\(Int(realElapsedS))s")
                        }
                    }
                }
            } else {
                // Specialist just completed their task — record approximate total
                // duration BEFORE dropping the start anchor. Wall-clock from
                // taskStartedAt is authoritative (already converted from base-equiv
                // ct). Fallback for the rare no-anchor case uses snap timing.
                if let snap = busySnapshots[item.uid] {
                    let totalRealMs: Int = {
                        if let startedAt = taskStartedAt[item.uid] {
                            return Int(now.timeIntervalSince(startedAt) * 1000)
                        }
                        return snap.lastCt + Int(now.timeIntervalSince(snap.lastCtAt) * 1000)
                    }()
                    let key = "\(snap.subTypeId):\(snap.actionType):\(snap.subTaskId)"
                    learnedDurations[key] = totalRealMs

                    // Surface table errors: predicted vs observed should agree closely.
                    // >5% divergence usually means a wrong timeBonus, a missing skill
                    // mapping, or a missing base duration entry.
                    let code = TaskCode(actionType: snap.actionType, subTaskID: snap.subTaskId)
                    if let predicted = ExplorerDurationRegistry.estimate(
                        task: code, subTypeId: snap.subTypeId, skills: item.skills) {
                        let observedSec = Double(totalRealMs) / 1000.0
                        let delta = abs(predicted - observedSec) / observedSec
                        if delta > 0.05 {
                            print("[ExplorerDuration] divergence \(Int(delta*100))% " +
                                  "key=\(key) skills=\(item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")) " +
                                  "predicted=\(Int(predicted))s observed=\(Int(observedSec))s")
                        }
                    }
                }
                taskStartedAt.removeValue(forKey: item.uid)
                busySnapshots.removeValue(forKey: item.uid)
                // Idle log — lets the user cross-reference skill IDs with the in-game
                // skill book (only viewable while the specialist is idle).
                if let prefix = Self.logPrefix(for: item.specialistType) {
                    let skillStr = item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
                    print("[\(prefix)] idle \"\(Self.displayName(for: item))\" uid=\(item.uid) type=\(item.subTypeId) skills=[\(skillStr)]")
                }
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
