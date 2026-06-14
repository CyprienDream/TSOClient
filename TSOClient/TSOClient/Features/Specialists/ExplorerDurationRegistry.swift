import Foundation

// Replicates fedorovvl/tso_client user_exp_time_matrix.js getTaskDuration():
//   t = base[task]
//   for each skill with level>0: t = t * (1 - reduction[level-1]/100)  (when scope matches)
//   t = t * 100 / timeBonus[subTypeId]
// Returns nil when the base duration, the subtype's time bonus, or any required
// piece is missing — the UI shows a dash rather than guessing.
enum ExplorerDurationRegistry {
    static let baseDurations: [TaskCode: Int]    = loaded.base
    static let timeBonus:     [Int: Int]         = loaded.bonus
    static let skills:        [Int: SkillEffect] = loaded.skills

    struct SkillEffect {
        let name: String
        let scope: Scope
        let reduction: [Int]   // percent, indexed by level-1
    }

    enum Scope: String, Decodable {
        case all
        case adventureAll      = "adventure_all"
        case treasureAll       = "treasure_all"
        case treasureShort     = "treasure_short"
        case treasureMedium    = "treasure_medium"
        case treasureLong      = "treasure_long"
        case treasureVeryLong  = "treasure_very_long"
        case treasureLongest   = "treasure_longest"

        // actionType: 1=Treasure, 2=Adventure. subTaskID per ExplorerTask.taskCode.
        func applies(to code: TaskCode) -> Bool {
            switch self {
            case .all:               return code.actionType == 1 || code.actionType == 2
            case .adventureAll:      return code.actionType == 2
            case .treasureAll:       return code.actionType == 1
            case .treasureShort:     return code.actionType == 1 && code.subTaskID == 0
            case .treasureMedium:    return code.actionType == 1 && code.subTaskID == 1
            case .treasureLong:      return code.actionType == 1 && code.subTaskID == 2
            case .treasureVeryLong:  return code.actionType == 1 && code.subTaskID == 3
            case .treasureLongest:   return code.actionType == 1 && code.subTaskID == 6
            }
        }
    }

    static func estimate(task code: TaskCode,
                         subTypeId: Int,
                         skills: [SpecialistSkill]) -> TimeInterval? {
        guard let base = baseDurations[code], base > 0 else { return nil }
        guard let bonus = timeBonus[subTypeId], bonus > 0 else { return nil }

        var t = Double(base)
        for sk in skills where sk.level > 0 {
            guard let eff = Self.skills[sk.id] else { continue }
            guard eff.scope.applies(to: code) else { continue }
            let idx = min(max(sk.level - 1, 0), eff.reduction.count - 1)
            t *= 1.0 - Double(eff.reduction[idx]) / 100.0
        }
        t = t * 100.0 / Double(bonus)
        return t
    }

    // ── Load ──────────────────────────────────────────────────────────────

    private struct Raw: Decodable {
        let baseDurations: [String: Int]
        let timeBonus:     [String: Int]
        let skills:        [SkillRaw]

        struct SkillRaw: Decodable {
            let name: String
            let skillId: Int?
            let scope: Scope
            let reduction: [Int]
        }
    }

    private struct Loaded {
        let base:   [TaskCode: Int]
        let bonus:  [Int: Int]
        let skills: [Int: SkillEffect]
    }

    private static let loaded: Loaded = {
        guard let url = Bundle.main.url(forResource: "explorer-durations", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[ExplorerDurationRegistry] explorer-durations.json not found")
            return Loaded(base: [:], bonus: [:], skills: [:])
        }
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            var base: [TaskCode: Int] = [:]
            for (k, v) in raw.baseDurations {
                let parts = k.split(separator: ",")
                guard parts.count == 2,
                      let at = Int(parts[0]), let st = Int(parts[1]) else { continue }
                base[TaskCode(actionType: at, subTaskID: st)] = v
            }
            var bonus: [Int: Int] = [:]
            for (k, v) in raw.timeBonus {
                if let id = Int(k) { bonus[id] = v }
            }
            var skillMap: [Int: SkillEffect] = [:]
            for s in raw.skills {
                guard let id = s.skillId else { continue }
                skillMap[id] = SkillEffect(name: s.name, scope: s.scope, reduction: s.reduction)
            }
            return Loaded(base: base, bonus: bonus, skills: skillMap)
        } catch {
            print("[ExplorerDurationRegistry] decode error: \(error)")
            return Loaded(base: [:], bonus: [:], skills: [:])
        }
    }()
}
