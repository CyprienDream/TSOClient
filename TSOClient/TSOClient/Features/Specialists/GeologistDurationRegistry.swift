import Foundation

// Same math as ExplorerDurationRegistry, applied to geologist tasks
// (actionType=0). Differences:
//   * timeBonus can be a flat Int OR {default, byTask: {"0,N": Int}} — resource-
//     specific subtypes like StoneCold (bonus 200 only for stone/marble/granite)
//     use the byTask shape.
//   * skill scope is "minerals" / "ores" — matches a fixed set of subTaskIDs.
//   * timeBonus entries with JSON null (unresolved subtypes like Lovely/Diligent/
//     Chummy) are skipped at load; estimate() returns nil for those, and the row
//     falls back to learned duration (see SpecialistRow.timerLabel).
enum GeologistDurationRegistry {

    // Same PFB constant as explorers — the buff cuts task time by 20% for both.
    static let pfbMultiplier: Double = ExplorerDurationRegistry.pfbMultiplier

    static let baseDurations: [TaskCode: Int] = loaded.base
    static let skills:        [Int: SkillEffect] = loaded.skills

    struct SkillEffect {
        let name: String
        let scope: Scope
        let reduction: [Int]
    }

    // Subset of tasks the skill affects. subTaskIDs come from geologist-
    // durations.json _dropSkills / _doc lines.
    enum Scope: String, Decodable {
        case minerals   // 0,0 stone · 0,2 marble · 0,5 coal · 0,6 granite · 0,8 salpeter
        case ores       // 0,1 copper · 0,3 iron · 0,4 gold · 0,7 titanium

        func applies(to code: TaskCode) -> Bool {
            guard code.actionType == 0 else { return false }
            switch self {
            case .minerals: return [0, 2, 5, 6, 8].contains(code.subTaskID)
            case .ores:     return [1, 3, 4, 7].contains(code.subTaskID)
            }
        }
    }

    static func estimate(task code: TaskCode,
                         subTypeId: Int,
                         skills: [SpecialistSkill],
                         pfbActive: Bool = false) -> TimeInterval? {
        guard let base = baseDurations[code], base > 0 else { return nil }
        guard let bonus = timeBonus(subTypeId: subTypeId, task: code), bonus > 0 else { return nil }

        var t = Double(base)
        for sk in skills where sk.level > 0 {
            guard let eff = Self.skills[sk.id] else { continue }
            guard eff.scope.applies(to: code) else { continue }
            let idx = min(max(sk.level - 1, 0), eff.reduction.count - 1)
            t *= 1.0 - Double(eff.reduction[idx]) / 100.0
        }
        t = t * 100.0 / Double(bonus)
        if pfbActive { t *= pfbMultiplier }
        return t
    }

    // Per-subtype bonus resolution. Flat entries return the same value for
    // every task; byTask entries fall back to `default` when the current task
    // isn't in the override map. Nil means the subtype's bonus is unknown
    // (JSON null) — caller treats it as "no estimate".
    static func timeBonus(subTypeId: Int, task code: TaskCode?) -> Int? {
        if let flat = loaded.bonusFlat[subTypeId] { return flat }
        guard let def = loaded.bonusDefault[subTypeId] else { return nil }
        if let code, let per = loaded.bonusByTask[subTypeId]?[code] { return per }
        return def
    }

    // ── Load ──────────────────────────────────────────────────────────────

    struct Loaded {
        let base:          [TaskCode: Int]
        let bonusFlat:     [Int: Int]
        let bonusDefault:  [Int: Int]
        let bonusByTask:   [Int: [TaskCode: Int]]
        let skills:        [Int: SkillEffect]

        static let empty = Loaded(base: [:], bonusFlat: [:], bonusDefault: [:], bonusByTask: [:], skills: [:])
    }

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> Loaded {
        guard let data = loader.loadData(name: "geologist-durations", ext: "json") else {
            logger.log("[GeologistDurationRegistry] geologist-durations.json not found")
            return .empty
        }
        // JSONSerialization instead of Codable because timeBonus values are
        // polymorphic (Int | Object | null) and JSON null must be silently
        // skipped — one-shot walk of the tree is simpler than a custom decoder.
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else {
            logger.log("[GeologistDurationRegistry] malformed JSON")
            return .empty
        }

        var base: [TaskCode: Int] = [:]
        if let bd = dict["baseDurations"] as? [String: Any] {
            for (k, v) in bd {
                guard let n = v as? Int, let code = parseCode(k) else { continue }
                base[code] = n
            }
        }

        var bonusFlat: [Int: Int] = [:]
        var bonusDefault: [Int: Int] = [:]
        var bonusByTask: [Int: [TaskCode: Int]] = [:]
        if let tb = dict["timeBonus"] as? [String: Any] {
            for (k, v) in tb {
                guard let id = Int(k) else { continue }
                if let n = v as? Int {
                    bonusFlat[id] = n
                } else if let obj = v as? [String: Any] {
                    if let def = obj["default"] as? Int { bonusDefault[id] = def }
                    if let per = obj["byTask"] as? [String: Any] {
                        var m: [TaskCode: Int] = [:]
                        for (kk, vv) in per {
                            guard let n = vv as? Int, let code = parseCode(kk) else { continue }
                            m[code] = n
                        }
                        bonusByTask[id] = m
                    }
                }
                // null / any other shape → skip (unresolved subtype)
            }
        }

        var skillMap: [Int: SkillEffect] = [:]
        if let sk = dict["skills"] as? [[String: Any]] {
            for entry in sk {
                guard let id = entry["skillId"] as? Int,
                      let name = entry["name"] as? String,
                      let scopeRaw = entry["scope"] as? String,
                      let scope = Scope(rawValue: scopeRaw),
                      let reduction = entry["reduction"] as? [Int] else { continue }
                skillMap[id] = SkillEffect(name: name, scope: scope, reduction: reduction)
            }
        }

        return Loaded(base: base,
                      bonusFlat: bonusFlat,
                      bonusDefault: bonusDefault,
                      bonusByTask: bonusByTask,
                      skills: skillMap)
    }

    private static func parseCode(_ s: String) -> TaskCode? {
        let parts = s.split(separator: ",")
        guard parts.count == 2,
              let at = Int(parts[0]), let st = Int(parts[1]) else { return nil }
        return TaskCode(actionType: at, subTaskID: st)
    }

    private static let loaded: Loaded = load()
}
