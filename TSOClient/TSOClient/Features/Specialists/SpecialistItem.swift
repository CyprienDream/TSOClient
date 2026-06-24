import Foundation

struct SpecialistItem: Identifiable, Equatable {
    let id: String          // "uid1:uid2"
    let uid1: Int
    let uid2: Int
    let specialistType: SpecialistKind
    let subTypeId: Int              // -1 if absent
    let subTypeName: String?        // CamelCase canonical name, e.g. "PirateExplorer"
    let name: String                // player's custom name (may be empty)
    let isIdle: Bool
    let skills: [SpecialistSkill]
    let collectedTime: Int?
    let bonusTime: Int?
    let taskEndTime: Double?
    let taskActionType: Int?        // nil when idle
    let taskSubTaskId: Int?         // nil when idle

    // Key into the learned-duration table.
    var durationKey: String? {
        guard let at = taskActionType, let st = taskSubTaskId else { return nil }
        return "\(subTypeId):\(at):\(st)"
    }
}

struct SpecialistSkill: Decodable, Hashable {
    let id: Int
    let level: Int
}
