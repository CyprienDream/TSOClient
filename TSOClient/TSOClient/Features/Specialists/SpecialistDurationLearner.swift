import Foundation
import Observation

// Owns the busy/idle state machine for specialists: tracks wall-clock task
// start anchors, learns total durations on completion, and persists the table
// across app restarts. Log-line formatting is delegated to
// SpecialistDurationLogger.
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
    private let durationLogger: SpecialistDurationLogger
    private let estimator: DurationEstimator
    private let persistKey: String

    init(store: KeyValueStore = UserDefaultsKeyValueStore(),
         logger: Logger = ConsoleLogger(),
         durationLogger: SpecialistDurationLogger? = nil,
         estimator: DurationEstimator = RegistryDurationEstimator(),
         persistKey: String = "tsoLearnedDurations") {
        self.store = store
        self.durationLogger = durationLogger ?? SpecialistDurationLogger(logger: logger, estimator: estimator)
        self.estimator = estimator
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
        let taskCode: TaskCode? = {
            guard let at = item.taskActionType, let st = item.taskSubTaskId else { return nil }
            return TaskCode(actionType: at, subTaskID: st)
        }()
        let bonus = estimator.timeBonus(subTypeId: item.subTypeId, task: taskCode)
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
        durationLogger.busy(item: item, ct: ct, actionType: at, subTaskId: st, bonus: bonus,
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
            durationLogger.divergence(
                subTypeId: snap.subTypeId, actionType: snap.actionType, subTaskId: snap.subTaskId,
                observedMs: totalRealMs, skills: item.skills, pfbActive: pfbActive)
        }
        taskStartedAt.removeValue(forKey: item.uid)
        busySnapshots.removeValue(forKey: item.uid)
        durationLogger.idle(item: item, formatter: formatter)
    }

    private func persistDuration(key: String, value: Int) {
        learnedDurations[key] = value
        store.set(learnedDurations, forKey: persistKey)
    }
}
