import Foundation

// Single source of truth for human-readable name overrides. Replaces the
// per-model `knownNames` / `subtypeDisplayOverrides` tables that used to live
// on BuffItem, BuildingItem, and SpecialistDisplayFormatter. Fallback rule
// (when an entry is absent): split the CamelCase identifier into words.
struct NamingRegistry: Decodable {
    let specialistSubtypes: [String: String]
    let buffs:              [String: String]
    let buildings:          [String: String]

    func specialistSubtypeOverride(raw: String) -> String? {
        specialistSubtypes[raw]
    }

    func buffName(raw: String) -> String {
        buffs[raw] ?? raw.camelCaseToWords
    }

    func buildingName(skinBase: String) -> String {
        buildings[skinBase] ?? skinBase.camelCaseToWords
    }

    static let empty = NamingRegistry(specialistSubtypes: [:], buffs: [:], buildings: [:])

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> NamingRegistry {
        guard let data = loader.loadData(name: "naming", ext: "json") else {
            logger.log("[NamingRegistry] naming.json not found")
            return .empty
        }
        do {
            return try JSONDecoder().decode(NamingRegistry.self, from: data)
        } catch {
            logger.log("[NamingRegistry] decode error: \(error)")
            return .empty
        }
    }

    static let `default`: NamingRegistry = load()
}
