import Foundation

// Per-SpecialistKind policy object: bundles the kind-specific behaviour
// (default task, current-task labelling, task-code availability) that used
// to live in three separate switch statements. Adding a new SpecialistKind
// means introducing a new conformer and wiring it into
// SpecialistKind.policy — no other call site changes.
protocol SpecialistKindPolicy {
    var defaultTaskCode: TaskCode { get }
    func taskLabel(for spec: SpecialistItem, code: TaskCode) -> String?
    func isAvailable(taskCode: TaskCode, for spec: SpecialistItem, playerLevel: Int?) -> Bool
}

struct GeologistPolicy: SpecialistKindPolicy {
    var defaultTaskCode: TaskCode { GeologistTask.findStone.taskCode }

    func taskLabel(for spec: SpecialistItem, code: TaskCode) -> String? {
        if code.actionType == 0, let task = GeologistTask(rawValue: code.subTaskID) {
            return task.label
        }
        return nil
    }

    func isAvailable(taskCode: TaskCode, for spec: SpecialistItem, playerLevel: Int?) -> Bool {
        if let task = GeologistTask(rawValue: taskCode.subTaskID), taskCode.actionType == 0 {
            return task.isAvailable(playerLevel: playerLevel)
        }
        return true
    }
}

struct ExplorerPolicy: SpecialistKindPolicy {
    var defaultTaskCode: TaskCode { ExplorerTask.treasureShort.taskCode }

    func taskLabel(for spec: SpecialistItem, code: TaskCode) -> String? {
        ExplorerTask.allCases.first { $0.taskCode == code }?.label
    }

    func isAvailable(taskCode: TaskCode, for spec: SpecialistItem, playerLevel: Int?) -> Bool {
        if let task = ExplorerTask.allCases.first(where: { $0.taskCode == taskCode }) {
            return task.isAvailable(skillIDs: spec.skills.map(\.id))
        }
        return true
    }
}

struct GeneralPolicy: SpecialistKindPolicy {
    var defaultTaskCode: TaskCode { generalStarMenuCode }

    func taskLabel(for spec: SpecialistItem, code: TaskCode) -> String? {
        code == generalStarMenuCode ? "Star Menu" : nil
    }

    func isAvailable(taskCode: TaskCode, for spec: SpecialistItem, playerLevel: Int?) -> Bool {
        true
    }
}

// Stub for unrecognised kinds: defaults to the general star-menu code as
// a harmless no-op, never reports a task label, and never gates a task.
// Behaviour preserved from the prior switch-default.
struct UnknownSpecialistPolicy: SpecialistKindPolicy {
    var defaultTaskCode: TaskCode { generalStarMenuCode }
    func taskLabel(for spec: SpecialistItem, code: TaskCode) -> String? { nil }
    func isAvailable(taskCode: TaskCode, for spec: SpecialistItem, playerLevel: Int?) -> Bool { true }
}

extension SpecialistKind {
    var policy: SpecialistKindPolicy {
        switch self {
        case .geologist: return GeologistPolicy()
        case .explorer:  return ExplorerPolicy()
        case .general:   return GeneralPolicy()
        case .unknown:   return UnknownSpecialistPolicy()
        }
    }
}
