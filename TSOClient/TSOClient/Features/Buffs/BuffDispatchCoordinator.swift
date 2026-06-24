import Foundation
import Observation

// View-model for the BuffsPanel. Owns per-category buff selection state, the
// master-buff override, and the bulk-buff dispatch loops.
@Observable
final class BuffDispatchCoordinator {
    // Selected buff name per category (keyed by category.id).
    var selectedBuff: [String: String] = [:]
    // Master picker selection; setting this overrides every visible group.
    var masterBuff: String = ""

    private let buffsStore: BuffsStore
    private let buildingsStore: BuildingsStore
    private let dispatcher: BuffDispatchPort
    private let classifier: BuffCategoryClassifier
    private let categoryRegistry: BuildingCategoryRegistry
    private let ignored: IgnoredBuildingsRegistry
    private let naming: NamingRegistry
    private let bulk: BulkDispatching
    private let logger: Logger

    init(buffsStore: BuffsStore,
         buildingsStore: BuildingsStore,
         dispatcher: BuffDispatchPort,
         classifier: BuffCategoryClassifier = .default,
         categoryRegistry: BuildingCategoryRegistry = .default,
         ignored: IgnoredBuildingsRegistry = .default,
         naming: NamingRegistry = .default,
         bulk: BulkDispatching = BulkDispatcher.default,
         logger: Logger = ConsoleLogger()) {
        self.buffsStore = buffsStore
        self.buildingsStore = buildingsStore
        self.dispatcher = dispatcher
        self.classifier = classifier
        self.categoryRegistry = categoryRegistry
        self.ignored = ignored
        self.naming = naming
        self.bulk = bulk
        self.logger = logger
    }

    var buildingBuffs: [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter { classifier.isBuildingBuff($0.buffName) }
    }

    // Fallback for any category lacking an explicit defaultBuff.
    private static let fallbackDefaultBuff = "ProductivityBuffLvl300"

    // Recognized tribute suffixes (case-insensitive). Order matters: the
    // longer `_mini_gold` must be checked first so we don't strip just
    // `_mini` from `Bookbinder_Mini_Gold` and leave a stray `_Gold` tail.
    private static let tributeSuffixes = ["_mini_gold", "_mini"]

    static func tributeStem(of skinBase: String) -> String? {
        let lower = skinBase.lowercased()
        for suffix in tributeSuffixes where lower.hasSuffix(suffix) {
            return String(skinBase.dropLast(suffix.count))
        }
        return nil
    }

    var groups: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] {
        var snapshot = categoryRegistry.categories
            .compactMap { category -> (category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])? in
                let buildings = buildingsStore.buildings(matchingSkinBases: category.skinBases)
                return buildings.isEmpty ? nil : (category, buildings)
            }
            .sorted {
                $0.category.displayName.localizedCaseInsensitiveCompare($1.category.displayName) == .orderedAscending
            }
        snapshot.append(contentsOf: unmappedGroups())
        applyDefaults(to: snapshot)
        return snapshot
    }

    // Surface any building skinBase not covered by the registry as its own
    // synthetic category. `_mini` skins are routed to the Tributes group with
    // an "X Tribute" display label; ignored skinBases (non-buffable structures
    // listed in ignored-buildings.json) are dropped entirely; everything else
    // lands in Unmapped. None get a default buff — user must opt in per row.
    private func unmappedGroups() -> [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] {
        let mappedBases = Set(categoryRegistry.categories.flatMap { $0.skinBases })
        let leftoverBases = buildingsStore.bySkinBase.keys
            .filter { !mappedBases.contains($0) }
            .sorted()
        return leftoverBases.compactMap { base in
            guard let buildings = buildingsStore.bySkinBase[base], !buildings.isEmpty else { return nil }
            if ignored.shouldIgnore(skinBase: base) { return nil }
            let displayName: String
            let group: BuildingGroup
            if let stem = Self.tributeStem(of: base) {
                displayName = naming.buildingName(skinBase: stem) + " Tribute"
                group = .tributes
            } else {
                displayName = naming.buildingName(skinBase: base)
                group = .unmapped
            }
            let category = BuildingCategory(
                displayName: displayName,
                skinBases: [base],
                defaultBuff: "",
                group: group.rawValue
            )
            return (category, buildings)
        }
    }

    // Same data as `groups`, bucketed by `category.group` and emitted in the
    // order defined by `BuildingGroup.allOrdered`. Empty buckets are skipped
    // so the panel stays compact for new accounts. Categories within a group
    // remain alpha-sorted (inherited from `groups`).
    var groupedSnapshot: [(group: BuildingGroup, items: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])])] {
        let flat = groups
        var buckets: [BuildingGroup: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]] = [:]
        for entry in flat {
            let key = BuildingGroup.from(entry.category.group)
            buckets[key, default: []].append(entry)
        }
        return BuildingGroup.allOrdered.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return (g, items)
        }
    }

    // Seed `selectedBuff` with each category's configured default the first
    // time a category appears, but only if the buff exists in inventory and
    // the user hasn't already picked something. Pure side-effect on
    // `selectedBuff`; idempotent.
    private func applyDefaults(to snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]) {
        for group in snapshot {
            // Unmapped categories never get a default — user must opt in per row.
            if group.category.group == BuildingGroup.unmapped.rawValue { continue }
            guard selectedBuff[group.category.id] == nil else { continue }
            let raw = group.category.defaultBuff ?? Self.fallbackDefaultBuff
            guard buffsStore.item(for: raw) != nil else { continue }
            selectedBuff[group.category.id] = raw
        }
    }

    // Apply the master selection across every visible category. Unmapped
    // categories are left alone so the master picker can't accidentally
    // schedule a buff against a building we don't recognize.
    func selectMasterBuff(_ buffName: String,
                          across snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]) {
        masterBuff = buffName
        for group in snapshot {
            if group.category.group == BuildingGroup.unmapped.rawValue { continue }
            selectedBuff[group.category.id] = buffName
        }
    }

    // Dispatch the same buff stack uid to every building in the group.
    // The server decrements the stack amount on each call. Returned Task lets
    // tests await completion.
    @discardableResult
    func buffAll(group: [BuildingsStore.BuildingItem], buffName: String) -> Task<Void, Never>? {
        guard let buff = buffsStore.item(for: buffName) else { return nil }
        return bulk.run(items: group) { [self] i, building in
            logger.log("[BuffAll] \(i + 1)/\(group.count) grid=\(building.gridIndex) " +
                       "buff=\(buff.uid1):\(buff.uid2)")
            dispatcher.dispatchBuff(
                buffUid1: buff.uid1,
                buffUid2: buff.uid2,
                targetGrid: building.gridIndex)
        }
    }

    // Dispatch each group's own `selectedBuff` to its buildings. Groups
    // without a selection (or whose selection is missing from inventory) are
    // skipped. Returns nil if nothing is dispatchable.
    @discardableResult
    func buffAllGroups(snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]) -> Task<Void, Never>? {
        struct Step { let building: BuildingsStore.BuildingItem; let buff: BuffsStore.BuffItem }
        var steps: [Step] = []
        for group in snapshot {
            // Unmapped categories are excluded from the master "Buff all".
            if group.category.group == BuildingGroup.unmapped.rawValue { continue }
            let name = selectedBuff[group.category.id] ?? ""
            guard !name.isEmpty, let buff = buffsStore.item(for: name) else { continue }
            for b in group.buildings {
                steps.append(Step(building: b, buff: buff))
            }
        }
        guard !steps.isEmpty else { return nil }
        let total = steps.count
        return bulk.run(items: steps) { [self] i, step in
            logger.log("[BuffAll] \(i + 1)/\(total) grid=\(step.building.gridIndex) " +
                       "buff=\(step.buff.uid1):\(step.buff.uid2)")
            dispatcher.dispatchBuff(
                buffUid1: step.buff.uid1,
                buffUid2: step.buff.uid2,
                targetGrid: step.building.gridIndex)
        }
    }
}
