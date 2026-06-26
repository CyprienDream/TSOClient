import Foundation

// Single config blob for the BuffsPanel, loaded from buff-panel-config.json
// via the shared ResourceLoader seam. Replaces the older split between
// buff-group-defaults.json and ignored-buildings.json — one editable file
// covers per-row default-buff assignments plus the skin patterns the panel
// should hide entirely.
//
// Sections:
//   - `subgroups` — keyed by BuildingCategory display name (e.g. "Copper
//                   Mine"). One entry per row in the panel; this is where
//                   the user picks the default buff for each building.
//   - `ignored`   — skin patterns whose buildings should not surface in
//                   the panel at all (garrisons, residences, decorations,
//                   depleted mines, etc.).
//
// Default-buff values are *display names* (e.g. "Aunt Irma's Feast"),
// not raw game identifiers — the coordinator resolves them back to the
// raw buffName via the live BuffsStore inventory at panel-read time.
// An empty string means "no default" so the user opts in per row.
struct BuffPanelConfig {
    let subgroups: [String: String]

    private let ignoredExact:   Set<String>
    private let ignoredContains: [String]   // already lowercased at load

    func defaultBuffDisplayName(forSubgroup subgroup: String) -> String? {
        subgroups[subgroup]
    }

    func shouldIgnore(skinBase: String) -> Bool {
        if ignoredExact.contains(skinBase) { return true }
        let lower = skinBase.lowercased()
        for c in ignoredContains where lower.contains(c) { return true }
        return false
    }

    init(subgroups: [String: String] = [:],
         ignoredExact: Set<String> = [],
         ignoredContains: [String] = []) {
        self.subgroups = subgroups
        self.ignoredExact = ignoredExact
        self.ignoredContains = ignoredContains.map { $0.lowercased() }
    }

    static let empty = BuffPanelConfig()

    private struct File: Decodable {
        struct Ignored: Decodable {
            let exact:                    [String]
            let containsCaseInsensitive:  [String]
        }
        let subgroups: [String: String]
        let ignored:   Ignored
    }

    static func load(loader: ResourceLoader = BundleResourceLoader(),
                     logger: Logger = ConsoleLogger()) -> BuffPanelConfig {
        guard let data = loader.loadData(name: "buff-panel-config", ext: "json") else {
            logger.log("[BuffPanelConfig] buff-panel-config.json not found")
            return .empty
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return BuffPanelConfig(
                subgroups: file.subgroups,
                ignoredExact: Set(file.ignored.exact),
                ignoredContains: file.ignored.containsCaseInsensitive
            )
        } catch {
            logger.log("[BuffPanelConfig] decode error: \(error)")
            return .empty
        }
    }

    static let `default`: BuffPanelConfig = load()
}
