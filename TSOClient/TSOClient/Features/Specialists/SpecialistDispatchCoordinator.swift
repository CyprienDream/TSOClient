import Foundation
import Observation

// View-model for the SpecialistsPanel. Owns per-row selection state and the
// bulk-dispatch loop so the panel can be pure layout.
@Observable
final class SpecialistDispatchCoordinator {
    var selectedTasks: [String: TaskCode] = [:]
    var selectedGrids: [String: Int] = [:]
    var bulkGeologistTask: GeologistTask = .findStone
    var bulkExplorerTask:  ExplorerTask  = .treasureShort

    // When enabled, every fresh SPECIALISTS payload triggers a sweep that
    // dispatches all idle explorers to `autoExplorerLoopTask`. Setting the
    // flag to true also kicks off an immediate sweep so the user doesn't
    // have to wait for the next zone reload; the kicked-off Task is stored
    // on `lastAutoLoopTask` so tests can await it. In addition, each
    // dispatched explorer gets a per-uid timer (`pendingReDispatches`) that
    // fires `ExplorerDurationRegistry.estimate + autoReDispatchBuffer`
    // seconds later and re-dispatches them — so the loop keeps running
    // mid-session without waiting for a zone reload.
    var autoExplorerLoopEnabled: Bool = false {
        didSet {
            defaults.set(autoExplorerLoopEnabled, forKey: Keys.autoExplorerLoopEnabled)
            if autoExplorerLoopEnabled, !oldValue {
                lastAutoLoopTask = runAutoExplorerLoop()
            }
            if !autoExplorerLoopEnabled, oldValue {
                cancelAllPendingReDispatches()
            }
        }
    }
    var autoExplorerLoopTask: ExplorerTask = .treasureShort {
        didSet { defaults.set(autoExplorerLoopTask.rawValue, forKey: Keys.autoExplorerLoopTask) }
    }
    // Slack added to the estimate before re-dispatching, so the server has
    // safely transitioned the explorer to idle. Settable for tests.
    var autoReDispatchBuffer: TimeInterval = 8
    private(set) var lastAutoLoopTask: Task<Void, Never>?
    private(set) var pendingReDispatches: [String: Task<Void, Never>] = [:]

    // Geologist auto-loop. Limited to Stone Cold (subTypeId=35) for now,
    // and zone-refresh-only (no per-uid timer) — geologist task durations
    // aren't reliable enough yet to predict completion.
    var autoGeologistLoopEnabled: Bool = false {
        didSet {
            defaults.set(autoGeologistLoopEnabled, forKey: Keys.autoGeologistLoopEnabled)
            if autoGeologistLoopEnabled, !oldValue {
                lastAutoGeologistLoopTask = runAutoGeologistLoop()
            }
        }
    }
    var autoGeologistLoopTask: GeologistTask = .findStone {
        didSet { defaults.set(autoGeologistLoopTask.rawValue, forKey: Keys.autoGeologistLoopTask) }
    }
    private(set) var lastAutoGeologistLoopTask: Task<Void, Never>?
    private static let stoneColdGeologistSubTypeID = 35

    private enum Keys {
        static let autoExplorerLoopEnabled  = "specialists.autoExplorerLoopEnabled"
        static let autoExplorerLoopTask     = "specialists.autoExplorerLoopTask"
        static let autoGeologistLoopEnabled = "specialists.autoGeologistLoopEnabled"
        static let autoGeologistLoopTask    = "specialists.autoGeologistLoopTask"
    }

    private let store: SpecialistsStore
    private let dispatcher: OutboundDispatching
    private let bulk: BulkDispatcher
    private let logger: Logger
    private let defaults: UserDefaults
    private let estimator: (SpecialistItem, TaskCode, Bool) -> TimeInterval?

    init(store: SpecialistsStore,
         dispatcher: OutboundDispatching,
         bulk: BulkDispatcher = .default,
         logger: Logger = ConsoleLogger(),
         defaults: UserDefaults = .standard,
         estimator: @escaping (SpecialistItem, TaskCode, Bool) -> TimeInterval? = { spec, code, pfb in
             ExplorerDurationRegistry.estimate(
                 task: code, subTypeId: spec.subTypeId,
                 skills: spec.skills, pfbActive: pfb)
         }) {
        self.store = store
        self.dispatcher = dispatcher
        self.bulk = bulk
        self.logger = logger
        self.defaults = defaults
        self.estimator = estimator
        self.autoExplorerLoopEnabled = defaults.bool(forKey: Keys.autoExplorerLoopEnabled)
        if let raw = defaults.string(forKey: Keys.autoExplorerLoopTask),
           let task = ExplorerTask(rawValue: raw) {
            self.autoExplorerLoopTask = task
        }
        self.autoGeologistLoopEnabled = defaults.bool(forKey: Keys.autoGeologistLoopEnabled)
        if let raw = defaults.object(forKey: Keys.autoGeologistLoopTask) as? Int,
           let task = GeologistTask(rawValue: raw) {
            self.autoGeologistLoopTask = task
        }
    }

    deinit {
        for (_, t) in pendingReDispatches { t.cancel() }
    }

    // Propagates a chosen task to every specialist of that kind, so the
    // individual row pickers reflect the bulk choice.
    func applyBulkTask(_ code: TaskCode, to kind: SpecialistKind) {
        for spec in store.items where spec.specialistType == kind {
            selectedTasks[spec.id] = code
        }
    }

    func resolvedTaskCode(for spec: SpecialistItem) -> TaskCode {
        selectedTasks[spec.id] ?? spec.specialistType.defaultTaskCode
    }

    func resolvedTargetGrid(for spec: SpecialistItem) -> Int {
        selectedGrids[spec.id] ?? 0
    }

    // Send the current per-row task to one specialist. Mirrors the optimistic
    // UI flip + AMF dispatch the panel did inline before.
    func dispatchOne(spec: SpecialistItem, taskCode: TaskCode, targetGrid: Int) {
        store.markDispatched(uid: spec.id,
                             actionType: taskCode.actionType,
                             subTaskId: taskCode.subTaskID)
        dispatcher.send(DispatchSpecialistCommand(
            uid1: spec.uid1, uid2: spec.uid2,
            actionType: taskCode.actionType,
            subTaskID: taskCode.subTaskID,
            targetGrid: targetGrid))
        scheduleAutoReDispatch(spec: spec, taskCode: taskCode)
    }

    // For explorers dispatched while the auto-loop is on, schedule a Task
    // that wakes after the predicted task duration and re-dispatches them
    // to `autoExplorerLoopTask`. Replaces any in-flight wake for the same
    // uid so back-to-back dispatches don't accumulate timers.
    private func scheduleAutoReDispatch(spec: SpecialistItem, taskCode: TaskCode) {
        guard autoExplorerLoopEnabled,
              spec.specialistType == .explorer,
              let estimate = estimator(spec, taskCode, store.pfbActive)
        else { return }
        pendingReDispatches[spec.id]?.cancel()
        let uid = spec.id
        let delaySec = estimate + autoReDispatchBuffer
        pendingReDispatches[uid] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delaySec) * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            self.pendingReDispatches.removeValue(forKey: uid)
            guard self.autoExplorerLoopEnabled,
                  let current = self.store.items.first(where: { $0.id == uid }),
                  current.specialistType == .explorer
            else { return }
            let next = self.autoExplorerLoopTask
            guard next.isAvailable(skillIDs: current.skills.map(\.id)) else { return }
            self.logger.log("[AutoLoop] timer wake — re-dispatching uid=\(uid) to \(next.label)")
            self.dispatchOne(spec: current, taskCode: next.taskCode, targetGrid: 0)
        }
    }

    private func cancelAllPendingReDispatches() {
        for (_, t) in pendingReDispatches { t.cancel() }
        pendingReDispatches.removeAll()
    }

    // Auto-loop entry point. Called from SpecialistsHandler after a fresh
    // SPECIALISTS payload is applied, and from the toggle's didSet. Quietly
    // no-ops when the toggle is off or no idle explorers can run the task.
    @discardableResult
    func runAutoExplorerLoop() -> Task<Void, Never>? {
        guard autoExplorerLoopEnabled else { return nil }
        let task = autoExplorerLoopTask
        let code = task.taskCode
        let candidates = store.items.filter {
            $0.specialistType == .explorer && $0.isIdle &&
            task.isAvailable(skillIDs: $0.skills.map(\.id))
        }
        guard !candidates.isEmpty else { return nil }
        logger.log("[AutoLoop] dispatching \(candidates.count) idle explorer(s) to \(task.label)")
        let plan = candidates.map { ($0, code, 0) }
        return bulk.run(items: plan) { [self] i, item in
            let (spec, tc, grid) = item
            dispatchOne(spec: spec, taskCode: tc, targetGrid: grid)
        }
    }

    // Geologist counterpart to runAutoExplorerLoop. Scoped to Stone Cold
    // (subTypeId=35) until we have enough data to estimate other subtypes
    // reliably. No per-uid timer — relies on the next SPECIALISTS payload
    // (typically a zone reload) to re-fire.
    @discardableResult
    func runAutoGeologistLoop() -> Task<Void, Never>? {
        guard autoGeologistLoopEnabled else { return nil }
        let task = autoGeologistLoopTask
        let code = task.taskCode
        let candidates = store.items.filter {
            $0.specialistType == .geologist &&
            $0.subTypeId == Self.stoneColdGeologistSubTypeID &&
            $0.isIdle &&
            task.isAvailable(playerLevel: store.playerLevel)
        }
        guard !candidates.isEmpty else { return nil }
        logger.log("[AutoLoop] dispatching \(candidates.count) idle Stone Cold geologist(s) to \(task.label)")
        let plan = candidates.map { ($0, code, 0) }
        return bulk.run(items: plan) { [self] i, item in
            let (spec, tc, grid) = item
            dispatchOne(spec: spec, taskCode: tc, targetGrid: grid)
        }
    }

    // Fires the currently-selected per-row task for every passed-in idle
    // specialist. Filters out task codes the spec can't actually run (level
    // gate, missing skill, etc). Returned Task lets tests await completion.
    @discardableResult
    func bulkDispatch(idleSpecialists: [SpecialistItem]) -> Task<Void, Never> {
        let plan: [(SpecialistItem, TaskCode, Int)] = idleSpecialists.compactMap { spec in
            let tc = resolvedTaskCode(for: spec)
            guard tc.isAvailable(for: spec, playerLevel: store.playerLevel) else { return nil }
            return (spec, tc, resolvedTargetGrid(for: spec))
        }
        logger.log("[Bulk] firing \(plan.count) of \(idleSpecialists.count) idle " +
                   "(skipped: \(idleSpecialists.count - plan.count) gated)")
        return bulk.run(items: plan) { [self] i, item in
            let (spec, tc, grid) = item
            logger.log("[Bulk] \(i + 1)/\(plan.count) uid=\(spec.uid1):\(spec.uid2) " +
                       "at=\(tc.actionType) st=\(tc.subTaskID)")
            dispatchOne(spec: spec, taskCode: tc, targetGrid: grid)
        }
    }
}
