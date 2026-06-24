import Foundation

// Read-only window over SpecialistDurationLearner's two observable maps,
// used by SpecialistRow to render countdowns. The row used to read these
// via pass-through properties on SpecialistsStore — coupling the store to
// the learner's storage shape. This protocol cuts that wire: the store
// stops faking ownership, the row depends on a narrow lookup contract,
// and the learner remains the single source of truth.
protocol SpecialistDurationLookup {
    func taskStartedAt(uid: String) -> Date?
    func learnedDurationMs(forKey key: String) -> Int?
}

extension SpecialistDurationLearner: SpecialistDurationLookup {
    func taskStartedAt(uid: String) -> Date? { taskStartedAt[uid] }
    func learnedDurationMs(forKey key: String) -> Int? { learnedDurations[key] }
}
