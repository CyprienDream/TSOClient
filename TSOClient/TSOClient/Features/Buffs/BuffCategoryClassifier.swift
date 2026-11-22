import Foundation

// Categories a buff name can belong to. Adding a new family of buffs
// (e.g. specialist buffs, event buffs) is now an enum case + a JSON entry
// rather than a new field on the classifier and a new ad-hoc helper.
enum BuffCategory: String, CaseIterable, Codable {
    case buildingBuffs
    case zoneBuffs
    // Buffs the UI should never surface — quest/story items that happen to
    // ride the ProductivityBuff/BattleBuff families but aren't applicable
    // to real buildings (e.g. Starfall quest extractor items). Hidden from
    // both the per-row dropdown and the zone-buff row.
    case excluded
}

// Decides which category a raw buff name belongs to. Data-driven via
// buff-categories.json so seasonal or promo variants don't require code
// edits.
struct BuffCategoryClassifier {
    struct Rule: Decodable {
        let prefixes: [String]
        let exact:    [String]
    }

    // Restricts a prefix's buffs to the buildings whose `BuildingCategory.group`
    // is either in `includeGroups` (allow-list) or NOT in `excludeGroups`
    // (deny-list). Exactly one of the two should be set per prefix. Used by
    // the per-row dropdown filter so e.g. `RecruitingBuff*` only shows in
    // Barracks rows and `ProductivityBuff*` doesn't leak into Barracks /
    // Bookbinder / Provision House rows.
    struct Scope: Decodable {
        let includeGroups: [String]?
        let excludeGroups: [String]?

        func allows(group: String) -> Bool {
            if let include = includeGroups { return include.contains(group) }
            if let exclude = excludeGroups { return !exclude.contains(group) }
            return true
        }
    }

    // Per-buff override by raw name. Used for buffs with a specific-building
    // scope (e.g. Damascene Hammer only on Weaponsmiths, Gold Fever only on
    // Gold Mine). When a buff appears in `scopeByName`, the prefix-level
    // group scope is skipped entirely: the buff shows up only in rows whose
    // `BuildingCategory.skinBases` overlap `skinBases`.
    struct NameScope: Decodable {
        let skinBases: [String]

        func applies(to categorySkinBases: [String]) -> Bool {
            categorySkinBases.contains { skinBases.contains($0) }
        }
    }

    let rules: [BuffCategory: Rule]
    // Prefix → scope. Longest-prefix match wins so `ProductivityBuffZone*`
    // (if ever added to scopes) beats the generic `ProductivityBuff` default.
    let scopeByPrefix: [String: Scope]
    // Raw buff name → explicit skinBase allow-list.
    let scopeByName: [String: NameScope]

    func matches(category: BuffCategory, name: String) -> Bool {
        guard let rule = rules[category] else { return false }
        if rule.exact.contains(name) { return true }
        for prefix in rule.prefixes where name.hasPrefix(prefix) { return true }
        return false
    }

    // Zone buffs apply to the whole zone, not individual buildings, and they
    // dispatch via a different opcode. The building-buff classifier excludes
    // anything that also matches a zone pattern so buffs like
    // `ProductivityBuffZoneWoodLvl1` (prefix overlap with `ProductivityBuff`)
    // don't leak into per-building dropdowns. Excluded (quest-item) buffs
    // are stripped from both categories.
    func isBuildingBuff(_ name: String) -> Bool {
        guard !matches(category: .excluded, name: name) else { return false }
        return matches(category: .buildingBuffs, name: name) &&
               !matches(category: .zoneBuffs, name: name)
    }

    func isZoneBuff(_ name: String) -> Bool {
        guard !matches(category: .excluded, name: name) else { return false }
        return matches(category: .zoneBuffs, name: name)
    }

    // True when `buff` is a building buff AND eligible to be dispatched on a
    // building whose category has `buildingGroup` and `skinBases`. Resolution
    // order:
    //   1. Reject anything that's not a building buff (zone / unrelated).
    //   2. Per-name override (`scopeByName`) wins when present — strict
    //      skinBase allow-list, ignores prefix group rules.
    //   3. Prefix group scope (`scopeByPrefix`, longest match wins).
    //   4. No rule found → allow (avoids silently hiding new buff families).
    func appliesTo(buff: String, buildingGroup: String, skinBases: [String]) -> Bool {
        guard isBuildingBuff(buff) else { return false }
        if let nameScope = scopeByName[buff] {
            return nameScope.applies(to: skinBases)
        }
        let matched = scopeByPrefix.keys
            .filter { buff.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        guard let key = matched, let scope = scopeByPrefix[key] else { return true }
        return scope.allows(group: buildingGroup)
    }

    // JSON shape — `zoneBuffs`, `scopeByPrefix`, and `scopeByName` are
    // optional for backward compatibility with older on-disk files that only
    // ship `buildingBuffs`. Missing rules / scopes default to empty
    // (zone-matches-nothing / allow-all-groups respectively).
    private struct File: Decodable {
        let buildingBuffs: Rule
        let zoneBuffs:     Rule?
        let excluded:      Rule?
        let scopeByPrefix: [String: Scope]?
        let scopeByName:   [String: NameScope]?

        var asRules: [BuffCategory: Rule] {
            var out: [BuffCategory: Rule] = [.buildingBuffs: buildingBuffs]
            if let zone = zoneBuffs { out[.zoneBuffs] = zone }
            if let ex = excluded { out[.excluded] = ex }
            return out
        }
    }

    static let empty = BuffCategoryClassifier(rules: [:], scopeByPrefix: [:], scopeByName: [:])

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> BuffCategoryClassifier {
        guard let data = loader.loadData(name: "buff-categories", ext: "json") else {
            logger.log("[BuffCategoryClassifier] buff-categories.json not found")
            return .empty
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return BuffCategoryClassifier(rules: file.asRules,
                                          scopeByPrefix: file.scopeByPrefix ?? [:],
                                          scopeByName: file.scopeByName ?? [:])
        } catch {
            logger.log("[BuffCategoryClassifier] decode error: \(error)")
            return .empty
        }
    }

    static let `default`: BuffCategoryClassifier = load()
}
