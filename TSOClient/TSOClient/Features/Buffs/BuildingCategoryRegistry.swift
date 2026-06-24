import Foundation
import SwiftUI

struct BuildingCategory: Identifiable, Decodable {
    var id: String { displayName }
    let displayName: String
    let skinBases: [String]
    // Raw buff name pre-selected for this category when no user choice has
    // been made yet (e.g. "ProductivityBuffLvl300" → Aunt Irma's Feast).
    // Falls back to AuntIrmasFeast for any category that omits this field.
    let defaultBuff: String?
    // Visual grouping key (e.g. "Mines", "Masons"). Categories that omit
    // this fall into the "Other" bucket rendered last.
    let group: String?

    init(displayName: String, skinBases: [String], defaultBuff: String? = nil, group: String? = nil) {
        self.displayName = displayName
        self.skinBases = skinBases
        self.defaultBuff = defaultBuff
        self.group = group
    }
}

// Display order + tint for each named group in the BuffsPanel. The order of
// `BuildingGroup.allOrdered` determines the on-screen section order; the
// "Other" bucket (anything with a nil/unknown `group`) is appended after.
enum BuildingGroup: String, CaseIterable {
    case mines    = "Mines"
    case masons   = "Masons"
    case smelters = "Smelters"
    case wood     = "Wood"
    case food     = "Food"
    case other    = "Other"

    static let allOrdered: [BuildingGroup] = [.mines, .masons, .smelters, .wood, .food, .other]

    var displayName: String { rawValue }

    var tint: Color {
        switch self {
        case .mines:    return Color(red: 0.72, green: 0.45, blue: 0.20) // copper/bronze
        case .masons:   return Color(red: 0.45, green: 0.48, blue: 0.52) // slate
        case .smelters: return Color(red: 0.88, green: 0.40, blue: 0.15) // forge orange
        case .wood:     return Color(red: 0.30, green: 0.60, blue: 0.30) // forest green
        case .food:     return Color(red: 0.85, green: 0.65, blue: 0.20) // wheat amber
        case .other:    return Color(red: 0.50, green: 0.50, blue: 0.55) // neutral
        }
    }

    static func from(_ raw: String?) -> BuildingGroup {
        guard let raw, let g = BuildingGroup(rawValue: raw) else { return .other }
        return g
    }
}

enum BuildingCategoryRegistry {
    static let categories: [BuildingCategory] = load()

    private static func load() -> [BuildingCategory] {
        guard let url = Bundle.main.url(forResource: "building-categories", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            ConsoleLogger().log("[BuildingCategoryRegistry] building-categories.json not found")
            return []
        }
        do {
            return try JSONDecoder().decode([BuildingCategory].self, from: data)
        } catch {
            ConsoleLogger().log("[BuildingCategoryRegistry] decode error: \(error)")
            return []
        }
    }
}
