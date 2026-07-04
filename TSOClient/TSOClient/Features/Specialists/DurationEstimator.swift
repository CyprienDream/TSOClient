import Foundation

// Estimates how long a specialist will take to complete a task. Hides
// the static registries so consumers (SpecialistDurationLogger,
// SpecialistDurationLearner, SpecialistRow, SpecialistDispatchCoordinator,
// AutoLoopStrategy) can be tested without production data files.
protocol DurationEstimator {
    func estimate(task: TaskCode,
                  subTypeId: Int,
                  skills: [SpecialistSkill],
                  pfbActive: Bool) -> TimeInterval?
    // ct (collectedTime) ticks at bonus/100 × real time. Task is optional
    // because callers may look up the bonus before the task fields are
    // unwrapped; when nil, per-task subtypes fall back to their `default`.
    func timeBonus(subTypeId: Int, task: TaskCode?) -> Int
}

// Production conformer that routes explorer tasks (actionType 1/2) to
// ExplorerDurationRegistry and geologist tasks (actionType 0) to the new
// GeologistDurationRegistry. Wherever a DurationEstimator is needed, this
// is the default.
struct RegistryDurationEstimator: DurationEstimator {
    func estimate(task: TaskCode,
                  subTypeId: Int,
                  skills: [SpecialistSkill],
                  pfbActive: Bool) -> TimeInterval? {
        if task.actionType == 0 {
            return GeologistDurationRegistry.estimate(
                task: task, subTypeId: subTypeId,
                skills: skills, pfbActive: pfbActive)
        }
        return ExplorerDurationRegistry.estimate(
            task: task, subTypeId: subTypeId,
            skills: skills, pfbActive: pfbActive)
    }

    func timeBonus(subTypeId: Int, task: TaskCode?) -> Int {
        if task?.actionType == 0 {
            return GeologistDurationRegistry.timeBonus(subTypeId: subTypeId, task: task) ?? 100
        }
        return ExplorerDurationRegistry.timeBonus[subTypeId] ?? 100
    }
}
