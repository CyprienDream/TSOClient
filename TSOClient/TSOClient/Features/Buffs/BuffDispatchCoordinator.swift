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
    private let bulk: BulkDispatcher
    private let logger: Logger

    init(buffsStore: BuffsStore,
         buildingsStore: BuildingsStore,
         dispatcher: BuffDispatchPort,
         classifier: BuffCategoryClassifier = .default,
         categoryRegistry: BuildingCategoryRegistry = .default,
         bulk: BulkDispatcher = .default,
         logger: Logger = ConsoleLogger()) {
        self.buffsStore = buffsStore
        self.buildingsStore = buildingsStore
        self.dispatcher = dispatcher
        self.classifier = classifier
        self.categoryRegistry = categoryRegistry
        self.bulk = bulk
        self.logger = logger
    }

    var buildingBuffs: [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter { classifier.isBuildingBuff($0.buffName) }
    }

    // Fallback for any category lacking an explicit defaultBuff.
    private static let fallbackDefaultBuff = "ProductivityBuffLvl300"

    var groups: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] {
        let snapshot = categoryRegistry.categories
            .compactMap { category -> (category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])? in
                let buildings = buildingsStore.buildings(matchingSkinBases: category.skinBases)
                return buildings.isEmpty ? nil : (category, buildings)
            }
            .sorted {
                $0.category.displayName.localizedCaseInsensitiveCompare($1.category.displayName) == .orderedAscending
            }
        applyDefaults(to: snapshot)
        return snapshot
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
            guard selectedBuff[group.category.id] == nil else { continue }
            let raw = group.category.defaultBuff ?? Self.fallbackDefaultBuff
            guard buffsStore.item(for: raw) != nil else { continue }
            selectedBuff[group.category.id] = raw
        }
    }

    // Apply the master selection across every visible category.
    func selectMasterBuff(_ buffName: String,
                          across snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]) {
        masterBuff = buffName
        for group in snapshot {
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

    @discardableResult
    func buffAllGroups(snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])],
                       buffName: String) -> Task<Void, Never>? {
        buffAll(group: snapshot.flatMap { $0.buildings }, buffName: buffName)
    }
}
