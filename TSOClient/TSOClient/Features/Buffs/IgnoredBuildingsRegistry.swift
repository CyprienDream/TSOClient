import Foundation

// Skin patterns whose buildings should not surface in the BuffsPanel at all
// (non-buffable structures: garrisons, residences, decorations, depleted mines,
// etc.). Loaded from ignored-buildings.json via the shared ResourceLoader seam.
//
// Casing matters in `exact` (skin strings like `Oilmill`, `Farmfield`, and
// `vases` are written exactly as the wire emits them). `containsCaseInsensitive`
// is matched in lowercase so a single rule covers e.g. `Garrison`,
// `AdmiralGarrison`, `TransportAdmiralGarrison`.
struct IgnoredBuildingsRegistry {
    let exact:                    Set<String>
    let containsCaseInsensitive:  [String]   // already lowercased at load

    func shouldIgnore(skinBase: String) -> Bool {
        if exact.contains(skinBase) { return true }
        let lower = skinBase.lowercased()
        for c in containsCaseInsensitive where lower.contains(c) { return true }
        return false
    }

    private struct File: Decodable {
        let exact:                    [String]
        let containsCaseInsensitive:  [String]
    }

    static let empty = IgnoredBuildingsRegistry(exact: [], containsCaseInsensitive: [])

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> IgnoredBuildingsRegistry {
        guard let data = loader.loadData(name: "ignored-buildings", ext: "json") else {
            logger.log("[IgnoredBuildingsRegistry] ignored-buildings.json not found")
            return .empty
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return IgnoredBuildingsRegistry(
                exact: Set(file.exact),
                containsCaseInsensitive: file.containsCaseInsensitive.map { $0.lowercased() }
            )
        } catch {
            logger.log("[IgnoredBuildingsRegistry] decode error: \(error)")
            return .empty
        }
    }

    static let `default`: IgnoredBuildingsRegistry = load()
}
