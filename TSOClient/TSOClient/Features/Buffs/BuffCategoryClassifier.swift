import Foundation

// Decides whether a buff name belongs to the "building buff" category shown in
// the BuffsPanel. Data-driven so adding a new productivity-buff family or a
// seasonal variant doesn't require editing the panel.
struct BuffCategoryClassifier {
    struct Rule: Decodable {
        let prefixes: [String]
        let exact:    [String]
    }

    let buildingBuffs: Rule

    func isBuildingBuff(_ name: String) -> Bool {
        if buildingBuffs.exact.contains(name) { return true }
        for prefix in buildingBuffs.prefixes where name.hasPrefix(prefix) { return true }
        return false
    }

    private struct File: Decodable {
        let buildingBuffs: Rule
    }

    static let empty = BuffCategoryClassifier(buildingBuffs: Rule(prefixes: [], exact: []))

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> BuffCategoryClassifier {
        guard let data = loader.loadData(name: "buff-categories", ext: "json") else {
            logger.log("[BuffCategoryClassifier] buff-categories.json not found")
            return .empty
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return BuffCategoryClassifier(buildingBuffs: file.buildingBuffs)
        } catch {
            logger.log("[BuffCategoryClassifier] decode error: \(error)")
            return .empty
        }
    }

    static let `default`: BuffCategoryClassifier = load()
}
