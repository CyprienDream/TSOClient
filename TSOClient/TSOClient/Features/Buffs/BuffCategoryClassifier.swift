import Foundation

// Categories a buff name can belong to. Adding a new family of buffs
// (e.g. specialist buffs, event buffs) is now an enum case + a JSON entry
// rather than a new field on the classifier and a new ad-hoc helper.
enum BuffCategory: String, CaseIterable, Codable {
    case buildingBuffs
}

// Decides which category a raw buff name belongs to. Data-driven via
// buff-categories.json so seasonal or promo variants don't require code
// edits.
struct BuffCategoryClassifier {
    struct Rule: Decodable {
        let prefixes: [String]
        let exact:    [String]
    }

    let rules: [BuffCategory: Rule]

    func matches(category: BuffCategory, name: String) -> Bool {
        guard let rule = rules[category] else { return false }
        if rule.exact.contains(name) { return true }
        for prefix in rule.prefixes where name.hasPrefix(prefix) { return true }
        return false
    }

    // Convenience shorthand kept for call-site readability. Equivalent to
    // matches(category: .buildingBuffs, name:).
    func isBuildingBuff(_ name: String) -> Bool {
        matches(category: .buildingBuffs, name: name)
    }

    // JSON shape preserved for backward compatibility — current file only
    // defines `buildingBuffs`. Add a new top-level field here and a matching
    // enum case to support a new category.
    private struct File: Decodable {
        let buildingBuffs: Rule

        var asRules: [BuffCategory: Rule] {
            [.buildingBuffs: buildingBuffs]
        }
    }

    static let empty = BuffCategoryClassifier(rules: [:])

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> BuffCategoryClassifier {
        guard let data = loader.loadData(name: "buff-categories", ext: "json") else {
            logger.log("[BuffCategoryClassifier] buff-categories.json not found")
            return .empty
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return BuffCategoryClassifier(rules: file.asRules)
        } catch {
            logger.log("[BuffCategoryClassifier] decode error: \(error)")
            return .empty
        }
    }

    static let `default`: BuffCategoryClassifier = load()
}
