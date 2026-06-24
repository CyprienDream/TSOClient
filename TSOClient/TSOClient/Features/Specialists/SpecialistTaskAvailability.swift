import Foundation

extension SpecialistKind {
    // Reasonable per-kind default the panel picks when the row hasn't been
    // touched yet. Routed through SpecialistKindPolicy so adding a kind
    // doesn't require editing this file.
    var defaultTaskCode: TaskCode { policy.defaultTaskCode }
}

extension TaskCode {
    // Is this task allowed for a given specialist at the current player level?
    // Delegates to the kind's policy.
    func isAvailable(for spec: SpecialistItem, playerLevel: Int?) -> Bool {
        spec.specialistType.policy.isAvailable(taskCode: self, for: spec, playerLevel: playerLevel)
    }
}

extension GeologistTask {
    func label(forPlayerLevel level: Int?) -> String {
        isAvailable(playerLevel: level) ? label : "\(label) (lvl \(minLevel))"
    }
}

extension SpecialistItem {
    // Human-readable label for the task this specialist is currently running.
    // Returns nil when the spec is idle or has no task code attached.
    var currentTaskLabel: String? {
        guard !isIdle,
              let at = taskActionType, let st = taskSubTaskId else { return nil }
        let code = TaskCode(actionType: at, subTaskID: st)
        return specialistType.policy.taskLabel(for: self, code: code) ?? "Task \(at)/\(st)"
    }
}
