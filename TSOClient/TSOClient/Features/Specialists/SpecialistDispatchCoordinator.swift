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

    private let store: SpecialistsStore
    private let dispatcher: OutboundDispatching
    private let bulk: BulkDispatcher
    private let logger: Logger

    init(store: SpecialistsStore,
         dispatcher: OutboundDispatching,
         bulk: BulkDispatcher = .default,
         logger: Logger = ConsoleLogger()) {
        self.store = store
        self.dispatcher = dispatcher
        self.bulk = bulk
        self.logger = logger
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
