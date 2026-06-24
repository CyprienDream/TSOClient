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
    private let dispatcher: OutboundDispatching
    private let classifier: BuffCategoryClassifier
    private let bulk: BulkDispatcher
    private let logger: Logger

    init(buffsStore: BuffsStore,
         buildingsStore: BuildingsStore,
         dispatcher: OutboundDispatching,
         classifier: BuffCategoryClassifier = .default,
         bulk: BulkDispatcher = .default,
         logger: Logger = ConsoleLogger()) {
        self.buffsStore = buffsStore
        self.buildingsStore = buildingsStore
        self.dispatcher = dispatcher
        self.classifier = classifier
        self.bulk = bulk
        self.logger = logger
    }

    var buildingBuffs: [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter { classifier.isBuildingBuff($0.buffName) }
    }

    var groups: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] {
        BuildingCategoryRegistry.categories
            .compactMap { category in
                let buildings = buildingsStore.buildings(matchingSkinBases: category.skinBases)
                return buildings.isEmpty ? nil : (category, buildings)
            }
            .sorted {
                $0.category.displayName.localizedCaseInsensitiveCompare($1.category.displayName) == .orderedAscending
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
            dispatcher.send(DispatchBuffCommand(
                buffUid1: buff.uid1,
                buffUid2: buff.uid2,
                targetGrid: building.gridIndex))
        }
    }

    @discardableResult
    func buffAllGroups(snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])],
                       buffName: String) -> Task<Void, Never>? {
        buffAll(group: snapshot.flatMap { $0.buildings }, buffName: buffName)
    }
}
