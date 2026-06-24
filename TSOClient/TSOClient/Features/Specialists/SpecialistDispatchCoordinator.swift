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

    // Geologist auto-loops, keyed by subTypeId. Each enabled entry sweeps its
    // own subtype on its own task — so Stone Cold can loop Granite while
    // Diligent loops Gold. Zone-refresh-only (no per-uid timer) — geologist
    // task durations aren't reliable enough yet to predict completion.
    struct GeologistLoopState: Equatable {
        var enabled: Bool = false
        var task: GeologistTask = .findStone
    }
    private(set) var geologistLoops: [Int: GeologistLoopState] = [:]
    private(set) var lastGeologistLoopTasks: [Int: Task<Void, Never>] = [:]

    func geologistLoopState(subTypeId: Int) -> GeologistLoopState {
        geologistLoops[subTypeId] ?? GeologistLoopState()
    }

    func setGeologistLoopEnabled(_ enabled: Bool, subTypeId: Int) {
        var state = geologistLoopState(subTypeId: subTypeId)
        let was = state.enabled
        state.enabled = enabled
        geologistLoops[subTypeId] = state
        defaults.set(enabled, forKey: Keys.geologistLoopEnabled(subTypeId: subTypeId))
        if enabled, !was {
            lastGeologistLoopTasks[subTypeId] = runAutoGeologistLoop(subTypeId: subTypeId)
        }
    }

    func setGeologistLoopTask(_ task: GeologistTask, subTypeId: Int) {
        var state = geologistLoopState(subTypeId: subTypeId)
        state.task = task
        geologistLoops[subTypeId] = state
        defaults.set(task.rawValue, forKey: Keys.geologistLoopTask(subTypeId: subTypeId))
    }

    private enum Keys {
        static let autoExplorerLoopEnabled  = "specialists.autoExplorerLoopEnabled"
        static let autoExplorerLoopTask     = "specialists.autoExplorerLoopTask"
        static func geologistLoopEnabled(subTypeId: Int) -> String {
            "specialists.geologistLoop.\(subTypeId).enabled"
        }
        static func geologistLoopTask(subTypeId: Int) -> String {
            "specialists.geologistLoop.\(subTypeId).task"
        }
    }

    private let store: SpecialistsStore
    private let dispatcher: SpecialistDispatchPort
    private let bulk: BulkDispatcher
    private let logger: Logger
    private let defaults: KeyValueStore
    private let estimator: DurationEstimator
    // Registered auto-loop strategies keyed by id. The runAuto* methods are
    // facades that look up by a known id; adding a new auto-loop kind means
    // registering a new strategy here, not adding more runAuto* methods.
    private var strategies: [String: any AutoLoopStrategy] = [:]

    init(store: SpecialistsStore,
         dispatcher: SpecialistDispatchPort,
         bulk: BulkDispatcher = .default,
         logger: Logger = ConsoleLogger(),
         defaults: KeyValueStore = UserDefaultsKeyValueStore(),
         estimator: DurationEstimator = RegistryDurationEstimator()) {
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
        for sub in GeologistAutoLoopSubtype.supported {
            var state = GeologistLoopState()
            state.enabled = defaults.bool(forKey: Keys.geologistLoopEnabled(subTypeId: sub.subTypeId))
            if let raw = defaults.object(forKey: Keys.geologistLoopTask(subTypeId: sub.subTypeId)) as? Int,
               let task = GeologistTask(rawValue: raw) {
                state.task = task
            }
            self.geologistLoops[sub.subTypeId] = state
        }
        registerStrategies()
    }

    private func registerStrategies() {
        let explorer = ExplorerAutoLoopStrategy(
            isEnabled:   { [weak self] in self?.autoExplorerLoopEnabled ?? false },
            currentTask: { [weak self] in self?.autoExplorerLoopTask ?? .treasureShort },
            buffer:      { [weak self] in self?.autoReDispatchBuffer ?? 8 },
            estimator:   estimator
        )
        register(explorer)
        for sub in GeologistAutoLoopSubtype.supported {
            let strategy = GeologistAutoLoopStrategy(
                subTypeId:    sub.subTypeId,
                getState:     { [weak self] in self?.geologistLoopState(subTypeId: sub.subTypeId) ?? GeologistLoopState() },
                subtypeLabel: sub.label
            )
            register(strategy)
        }
    }

    private func register(_ strategy: any AutoLoopStrategy) {
        strategies[strategy.id] = strategy
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
        dispatcher.dispatchSpecialist(
            uid1: spec.uid1, uid2: spec.uid2,
            actionType: taskCode.actionType,
            subTaskID: taskCode.subTaskID,
            targetGrid: targetGrid)
        scheduleAutoReDispatch(spec: spec, taskCode: taskCode)
    }

    // After every dispatch, ask each strategy whether it wants to arm a
    // wake-up timer for this spec. Only one strategy is expected to claim
    // a given spec (e.g. ExplorerAutoLoopStrategy claims idle explorers
    // when the loop is on); the first non-nil delay wins. Replaces any
    // in-flight wake for the same uid so back-to-back dispatches don't
    // accumulate timers.
    private func scheduleAutoReDispatch(spec: SpecialistItem, taskCode: TaskCode) {
        let pfb = store.pfbActive
        let claim: (strategyId: String, delay: TimeInterval)? = {
            for strategy in strategies.values {
                if let d = strategy.reDispatchDelay(for: spec, taskCode: taskCode, pfbActive: pfb) {
                    return (strategy.id, d)
                }
            }
            return nil
        }()
        guard let (strategyId, delaySec) = claim else { return }
        pendingReDispatches[spec.id]?.cancel()
        let uid = spec.id
        pendingReDispatches[uid] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delaySec) * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            self.pendingReDispatches.removeValue(forKey: uid)
            // Original behaviour: at wake, re-check enabled/kind/skill but
            // not isIdle (server-side state may not have flipped yet).
            guard let strategy = self.strategies[strategyId],
                  let current = self.store.items.first(where: { $0.id == uid }),
                  strategy.matches(spec: current, playerLevel: self.store.playerLevel)
            else { return }
            let next = strategy.taskCode(for: current)
            self.logger.log("[AutoLoop] timer wake — re-dispatching uid=\(uid) to \(strategy.taskLogLabel)")
            self.dispatchOne(spec: current, taskCode: next, targetGrid: 0)
        }
    }

    private func cancelAllPendingReDispatches() {
        for (_, t) in pendingReDispatches { t.cancel() }
        pendingReDispatches.removeAll()
    }

    // Auto-loop entry point. Called from SpecialistsHandler after a fresh
    // SPECIALISTS payload is applied, and from the toggle's didSet.
    // Delegates to the registered explorer strategy.
    @discardableResult
    func runAutoExplorerLoop() -> Task<Void, Never>? {
        runStrategy(id: "auto-loop-explorer")
    }

    // Geologist counterpart. Fires every registered per-subtype geologist
    // strategy. No per-uid timer — the strategies' reDispatchDelay returns
    // nil — so the loop relies on the next SPECIALISTS payload to re-fire.
    func runAutoGeologistLoop() {
        for sub in GeologistAutoLoopSubtype.supported {
            if let t = runAutoGeologistLoop(subTypeId: sub.subTypeId) {
                lastGeologistLoopTasks[sub.subTypeId] = t
            }
        }
    }

    @discardableResult
    func runAutoGeologistLoop(subTypeId: Int) -> Task<Void, Never>? {
        runStrategy(id: "auto-loop-geologist-\(subTypeId)")
    }

    // Runs a single registered strategy. Returns the bulk-dispatch Task or
    // nil if the strategy has no candidates.
    @discardableResult
    private func runStrategy(id: String) -> Task<Void, Never>? {
        guard let strategy = strategies[id] else { return nil }
        let cands = strategy.candidates(in: store.items, playerLevel: store.playerLevel)
        guard !cands.isEmpty else { return nil }
        logger.log("[AutoLoop] dispatching \(cands.count) idle \(strategy.logLabel)(s) to \(strategy.taskLogLabel)")
        let plan = cands.map { spec in (spec, strategy.taskCode(for: spec), 0) }
        return bulk.run(items: plan) { [self] _, item in
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
