import Foundation

// A pluggable rule for "which specialists should the coordinator
// auto-dispatch right now, and what should they do?". Each strategy owns
// its own id (used for log lines + coordinator lookup) and answers four
// questions independently:
//   1. Does this strategy claim this spec at all (enabled + kind + gating)?
//      → `matches(spec:playerLevel:)`. Used at timer-wake to decide whether
//      to re-dispatch; deliberately does NOT include the isIdle check.
//   2. Which currently-visible specialists are eligible (matches + idle)?
//      → default `candidates(in:playerLevel:)` filters `matches` by isIdle.
//   3. What task code should each candidate run? → `taskCode(for:)`.
//   4. After dispatch, should the coordinator schedule a wake-up to
//      re-dispatch the same uid, and after how long? → `reDispatchDelay`.
//
// Adding a new auto-loop kind = adding a strategy + registering it on the
// coordinator. The coordinator's runAutoExplorerLoop / runAutoGeologistLoop
// methods are thin facades that look the strategy up by id.
protocol AutoLoopStrategy {
    var id: String { get }
    // Short label used in [AutoLoop] log lines (e.g. "explorer", "Stone Cold geologist").
    var logLabel: String { get }
    // Per-strategy task label (e.g. autoExplorerLoopTask.label) appended to the log line.
    var taskLogLabel: String { get }

    // True if this strategy would claim the spec (loop enabled, kind /
    // subtype match, skill / level gating satisfied). Does NOT consider
    // isIdle — callers that want eligible-right-now should use
    // `candidates(in:playerLevel:)`.
    func matches(spec: SpecialistItem, playerLevel: Int?) -> Bool

    func taskCode(for spec: SpecialistItem) -> TaskCode

    // Seconds to wait before re-dispatching this spec mid-session, or nil
    // for strategies that only loop on the next SPECIALISTS payload.
    func reDispatchDelay(for spec: SpecialistItem,
                         taskCode: TaskCode,
                         pfbActive: Bool) -> TimeInterval?
}

extension AutoLoopStrategy {
    func candidates(in items: [SpecialistItem], playerLevel: Int?) -> [SpecialistItem] {
        items.filter { $0.isIdle && matches(spec: $0, playerLevel: playerLevel) }
    }
}

// Explorer loop: enabled by `autoExplorerLoopEnabled`, dispatches every
// idle explorer that can run the currently-selected `autoExplorerLoopTask`,
// and arms a per-uid timer for autoReDispatchBuffer + predicted-duration
// seconds.
struct ExplorerAutoLoopStrategy: AutoLoopStrategy {
    let id = "auto-loop-explorer"
    let isEnabled: () -> Bool
    let currentTask: () -> ExplorerTask
    let buffer: () -> TimeInterval
    let estimator: DurationEstimator

    var logLabel: String { "explorer" }
    var taskLogLabel: String { currentTask().label }

    func matches(spec: SpecialistItem, playerLevel: Int?) -> Bool {
        guard isEnabled(), spec.specialistType == .explorer else { return false }
        return currentTask().isAvailable(skillIDs: spec.skills.map(\.id))
    }

    func taskCode(for spec: SpecialistItem) -> TaskCode { currentTask().taskCode }

    func reDispatchDelay(for spec: SpecialistItem,
                         taskCode: TaskCode,
                         pfbActive: Bool) -> TimeInterval? {
        guard isEnabled(), spec.specialistType == .explorer,
              let est = estimator.estimate(task: taskCode, subTypeId: spec.subTypeId,
                                           skills: spec.skills, pfbActive: pfbActive)
        else { return nil }
        return est + buffer()
    }
}

// Geologist loop for a single subtype (Stone Cold, Diligent, …). No per-uid
// timer — geologist task durations aren't reliable enough to predict
// completion, so the loop relies on the next SPECIALISTS payload to re-fire.
struct GeologistAutoLoopStrategy: AutoLoopStrategy {
    let subTypeId: Int
    let getState: () -> SpecialistDispatchCoordinator.GeologistLoopState
    let subtypeLabel: String

    var id: String { "auto-loop-geologist-\(subTypeId)" }
    var logLabel: String { "\(subtypeLabel) geologist" }
    var taskLogLabel: String { getState().task.label }

    func matches(spec: SpecialistItem, playerLevel: Int?) -> Bool {
        let state = getState()
        guard state.enabled,
              spec.specialistType == .geologist,
              spec.subTypeId == subTypeId else { return false }
        return state.task.isAvailable(playerLevel: playerLevel)
    }

    func taskCode(for spec: SpecialistItem) -> TaskCode { getState().task.taskCode }

    func reDispatchDelay(for spec: SpecialistItem,
                         taskCode: TaskCode,
                         pfbActive: Bool) -> TimeInterval? { nil }
}
