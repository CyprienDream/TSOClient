import Foundation

extension SpecialistKind {
    // Reasonable per-kind default the panel picks when the row hasn't been
    // touched yet. Unknown also returns the general code as a harmless stub —
    // the row's task controls suppress dispatch for unknown rows.
    var defaultTaskCode: TaskCode {
        switch self {
        case .geologist: return GeologistTask.findStone.taskCode
        case .explorer:  return ExplorerTask.treasureShort.taskCode
        case .general, .unknown: return generalStarMenuCode
        }
    }
}

extension TaskCode {
    // Is this task allowed for a given specialist at the current player level?
    // For unknown task codes (e.g. General star-menu) the answer is yes — the
    // gating only applies to geologist/explorer subtasks.
    func isAvailable(for spec: SpecialistItem, playerLevel: Int?) -> Bool {
        if spec.specialistType == .geologist,
           let task = GeologistTask(rawValue: subTaskID), actionType == 0 {
            return task.isAvailable(playerLevel: playerLevel)
        }
        if spec.specialistType == .explorer,
           let task = ExplorerTask.allCases.first(where: { $0.taskCode == self }) {
            return task.isAvailable(skillIDs: spec.skills.map(\.id))
        }
        return true
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
        switch specialistType {
        case .geologist:
            if at == 0, let task = GeologistTask(rawValue: st) { return task.label }
        case .explorer:
            if let task = ExplorerTask.allCases.first(where: { $0.taskCode == code }) {
                return task.label
            }
        case .general:
            if code == generalStarMenuCode { return "Star Menu" }
        case .unknown:
            break
        }
        return "Task \(at)/\(st)"
    }
}
