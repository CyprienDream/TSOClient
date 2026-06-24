import Foundation
import Observation

// Owns the busy/idle state machine for specialists: tracks wall-clock task
// start anchors, learns total durations on completion, and persists the table
// across app restarts. Logging is funnelled through an injected Logger so
// tests can capture it.
//
// ct (collectedTime) is in base-time-equivalent milliseconds: it advances at
// bonus/100 × real time, so a 3× subtype's ct ticks 3× wall clock. Real
// elapsed seconds = ct/1000 × 100/bonus.
@Observable
final class SpecialistDurationLearner {
    private(set) var taskStartedAt: [String: Date] = [:]
    private(set) var learnedDurations: [String: Int] = [:]

    private struct BusySnapshot {
        let subTypeId: Int
        let actionType: Int
        let subTaskId: Int
        let lastCt: Int
        let lastCtAt: Date
    }
    private var busySnapshots: [String: BusySnapshot] = [:]

    private let store: KeyValueStore
    private let logger: Logger
    private let persistKey: String

    init(store: KeyValueStore = UserDefaultsKeyValueStore(),
         logger: Logger = ConsoleLogger(),
         persistKey: String = "tsoLearnedDurations") {
        self.store = store
        self.logger = logger
        self.persistKey = persistKey
        if let saved = store.dictionary(forKey: persistKey) as? [String: Int] {
            self.learnedDurations = saved
        }
    }

    func process(payload: InboundMessage.SpecialistsPayload,
                 formatter: SpecialistDisplayFormatter,
                 pfbActive: Bool = false,
                 now: Date = Date()) {
        let nextUids = Set(payload.items.map { $0.uid })

        // Drop stale anchors for specialists no longer in the list.
        for uid in taskStartedAt.keys where !nextUids.contains(uid) {
            taskStartedAt.removeValue(forKey: uid)
        }

        for item in payload.items {
            if !item.isIdle {
                applyBusyTransition(item: item, formatter: formatter, pfbActive: pfbActive, now: now)
            } else {
                applyIdleTransition(item: item, formatter: formatter, pfbActive: pfbActive, now: now)
            }
        }

        for uid in busySnapshots.keys where !nextUids.contains(uid) {
            busySnapshots.removeValue(forKey: uid)
        }
    }

    // Optimistic flip after a manual dispatch. Seeds the snapshot so the
    // learning loop has a start anchor even if the next zone load is far off.
    func markDispatched(uid: String,
                        subTypeId: Int,
                        actionType: Int,
                        subTaskId: Int,
                        now: Date = Date()) {
        taskStartedAt[uid] = now
        busySnapshots[uid] = BusySnapshot(
            subTypeId: subTypeId,
            actionType: actionType,
            subTaskId: subTaskId,
            lastCt: 0,
            lastCtAt: now
        )
    }

    func clear() {
        taskStartedAt = [:]
        busySnapshots = [:]
    }

    // ── Private ──────────────────────────────────────────────────────────

    private func applyBusyTransition(item: InboundMessage.SpecialistsPayload.Item,
                                     formatter: SpecialistDisplayFormatter,
                                     pfbActive: Bool,
                                     now: Date) {
        // Non-explorer subtypes have no bonus in the registry — default to 100
        // (no scaling) which keeps the current geologist/general behavior.
        let bonus = ExplorerDurationRegistry.timeBonus[item.subTypeId] ?? 100
        if let ct = item.collectedTime {
            let realElapsedSec = Double(ct) / 1000.0 * 100.0 / Double(bonus)
            taskStartedAt[item.uid] = now.addingTimeInterval(-realElapsedSec)
        } else if taskStartedAt[item.uid] == nil {
            taskStartedAt[item.uid] = now
        }

        guard let ct = item.collectedTime,
              let at = item.taskActionType,
              let st = item.taskSubTaskId else { return }

        busySnapshots[item.uid] = BusySnapshot(
            subTypeId: item.subTypeId,
            actionType: at,
            subTaskId: st,
            lastCt: ct,
            lastCtAt: now
        )
        logBusy(item: item, ct: ct, actionType: at, subTaskId: st, bonus: bonus,
                pfbActive: pfbActive, formatter: formatter)
    }

    private func applyIdleTransition(item: InboundMessage.SpecialistsPayload.Item,
                                     formatter: SpecialistDisplayFormatter,
                                     pfbActive: Bool,
                                     now: Date) {
        if let snap = busySnapshots[item.uid] {
            let totalRealMs: Int = {
                if let startedAt = taskStartedAt[item.uid] {
                    return Int(now.timeIntervalSince(startedAt) * 1000)
                }
                return snap.lastCt + Int(now.timeIntervalSince(snap.lastCtAt) * 1000)
            }()
            let key = "\(snap.subTypeId):\(snap.actionType):\(snap.subTaskId)"
            persistDuration(key: key, value: totalRealMs)
            logDivergence(snap: snap, observedMs: totalRealMs, skills: item.skills, pfbActive: pfbActive)
        }
        taskStartedAt.removeValue(forKey: item.uid)
        busySnapshots.removeValue(forKey: item.uid)
        logIdle(item: item, formatter: formatter)
    }

    private func persistDuration(key: String, value: Int) {
        learnedDurations[key] = value
        store.set(learnedDurations, forKey: persistKey)
    }

    private static func logPrefix(for kind: SpecialistKind) -> String? {
        switch kind {
        case .explorer:  return "ExplorerDuration"
        case .geologist: return "GeologistDuration"
        case .general, .unknown: return nil
        }
    }

    private func logBusy(item: InboundMessage.SpecialistsPayload.Item,
                         ct: Int, actionType: Int, subTaskId: Int, bonus: Int,
                         pfbActive: Bool,
                         formatter: SpecialistDisplayFormatter) {
        guard let prefix = Self.logPrefix(for: item.specialistType) else { return }
        let code = TaskCode(actionType: actionType, subTaskID: subTaskId)
        let skillStr = item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
        let realElapsedS = Double(ct) / 1000.0 * 100.0 / Double(bonus)
        let name = formatter.compactDisplayName(forPayloadItem: item)
        if let predicted = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: item.subTypeId, skills: item.skills, pfbActive: pfbActive) {
            let remainingS = max(0, predicted - realElapsedS)
            logger.log("[\(prefix)] busy \"\(name)\" uid=\(item.uid) type=\(item.subTypeId) " +
                       "task=\(actionType),\(subTaskId) skills=[\(skillStr)] " +
                       "predicted=\(Int(predicted))s elapsed=\(Int(realElapsedS))s " +
                       "remaining=\(Int(remainingS))s")
        } else {
            logger.log("[\(prefix)] busy \"\(name)\" uid=\(item.uid) type=\(item.subTypeId) " +
                       "task=\(actionType),\(subTaskId) skills=[\(skillStr)] " +
                       "elapsed=\(Int(realElapsedS))s")
        }
    }

    private func logIdle(item: InboundMessage.SpecialistsPayload.Item,
                         formatter: SpecialistDisplayFormatter) {
        guard let prefix = Self.logPrefix(for: item.specialistType) else { return }
        let skillStr = item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
        let name = formatter.compactDisplayName(forPayloadItem: item)
        logger.log("[\(prefix)] idle \"\(name)\" uid=\(item.uid) type=\(item.subTypeId) skills=[\(skillStr)]")
    }

    private func logDivergence(snap: BusySnapshot, observedMs: Int,
                               skills: [SpecialistSkill], pfbActive: Bool) {
        // Surface table errors: predicted vs observed should agree closely.
        // >5% divergence usually means a wrong timeBonus, a missing skill
        // mapping, or a missing base duration entry.
        let code = TaskCode(actionType: snap.actionType, subTaskID: snap.subTaskId)
        guard let predicted = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: snap.subTypeId, skills: skills, pfbActive: pfbActive) else { return }
        let observedSec = Double(observedMs) / 1000.0
        let delta = abs(predicted - observedSec) / observedSec
        guard delta > 0.05 else { return }
        let key = "\(snap.subTypeId):\(snap.actionType):\(snap.subTaskId)"
        let skillStr = skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
        logger.log("[ExplorerDuration] divergence \(Int(delta*100))% " +
                   "key=\(key) skills=\(skillStr) " +
                   "predicted=\(Int(predicted))s observed=\(Int(observedSec))s")
    }
}
