import Foundation

struct BuildingCategory: Identifiable, Decodable {
    var id: String { displayName }
    let displayName: String
    let skinBases: [String]
}

enum BuildingCategoryRegistry {
    static let categories: [BuildingCategory] = load()

    private static func load() -> [BuildingCategory] {
        guard let url = Bundle.main.url(forResource: "building-categories", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[BuildingCategoryRegistry] building-categories.json not found")
            return []
        }
        do {
            return try JSONDecoder().decode([BuildingCategory].self, from: data)
        } catch {
            print("[BuildingCategoryRegistry] decode error: \(error)")
            return []
        }
    }
}
