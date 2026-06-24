import Foundation

// Estimates how long a specialist will take to complete a task. Hides
// the static ExplorerDurationRegistry so consumers (SpecialistDurationLogger,
// SpecialistDurationLearner, SpecialistRow, SpecialistDispatchCoordinator,
// AutoLoopStrategy) can be tested without the production registry.
protocol DurationEstimator {
    func estimate(task: TaskCode,
                  subTypeId: Int,
                  skills: [SpecialistSkill],
                  pfbActive: Bool) -> TimeInterval?
    // ct (collectedTime) ticks at bonus/100 × real time. Non-explorer
    // subtypes have no bonus in the registry — production conformer
    // returns 100 for those, preserving the prior nil-coalesce default.
    func timeBonus(subTypeId: Int) -> Int
}

// Production conformer that delegates to the static registry. Wherever a
// DurationEstimator is needed, this is the default.
struct RegistryDurationEstimator: DurationEstimator {
    func estimate(task: TaskCode,
                  subTypeId: Int,
                  skills: [SpecialistSkill],
                  pfbActive: Bool) -> TimeInterval? {
        ExplorerDurationRegistry.estimate(
            task: task, subTypeId: subTypeId,
            skills: skills, pfbActive: pfbActive)
    }
    func timeBonus(subTypeId: Int) -> Int {
        ExplorerDurationRegistry.timeBonus[subTypeId] ?? 100
    }
}
