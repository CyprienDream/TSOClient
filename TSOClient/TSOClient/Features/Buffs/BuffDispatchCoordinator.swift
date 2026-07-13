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

    // Transient banner surfaced by BuffsPanel when buildings are buffed
    // (per-category bulk or master "Buff all"). Mirrors the specialist
    // dispatch banner — bursts within `buffBannerHideDelay` of the last
    // dispatch coalesce into one banner.
    private(set) var buffBannerText: String?
    var buffBannerHideDelay: TimeInterval = 2.5
    private var buffBannerCount: Int = 0
    private var buffBannerLastBuff: String?
    private var buffBannerHideTask: Task<Void, Never>?

    private let buffsStore: BuffsStore
    private let buildingsStore: BuildingsStore
    private let dispatcher: BuffDispatchPort
    private let classifier: BuffCategoryClassifier
    private let categoryRegistry: BuildingCategoryRegistry
    private let panelConfig: BuffPanelConfig
    private let naming: NamingRegistry
    private let bulk: BulkDispatching
    private let logger: Logger

    init(buffsStore: BuffsStore,
         buildingsStore: BuildingsStore,
         dispatcher: BuffDispatchPort,
         classifier: BuffCategoryClassifier = .default,
         categoryRegistry: BuildingCategoryRegistry = .default,
         panelConfig: BuffPanelConfig = .default,
         naming: NamingRegistry = .default,
         bulk: BulkDispatching = BulkDispatcher.default,
         logger: Logger = ConsoleLogger()) {
        self.buffsStore = buffsStore
        self.buildingsStore = buildingsStore
        self.dispatcher = dispatcher
        self.classifier = classifier
        self.categoryRegistry = categoryRegistry
        self.panelConfig = panelConfig
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
    // listed under `ignored` in buff-panel-config.json) are dropped entirely;
    // everything else lands in Unmapped. None get a default buff — user must
    // opt in per row.
    private func unmappedGroups() -> [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] {
        let mappedBases = Set(categoryRegistry.categories.flatMap { $0.skinBases })
        let leftoverBases = buildingsStore.bySkinBase.keys
            .filter { !mappedBases.contains($0) }
            .sorted()
        return leftoverBases.compactMap { base in
            guard let buildings = buildingsStore.bySkinBase[base], !buildings.isEmpty else { return nil }
            if panelConfig.shouldIgnore(skinBase: base) { return nil }
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

    // `groupedSnapshot` filtered by a user-supplied search query. Match is a
    // case-insensitive substring check against each category's display name;
    // whitespace-only queries are treated as empty (returns the full snapshot
    // unchanged). Sections with no surviving categories are dropped.
    func filteredGroupedSnapshot(
        matching query: String
    ) -> [(group: BuildingGroup, items: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])])] {
        let sections = groupedSnapshot
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.items.filter {
                $0.category.displayName.localizedCaseInsensitiveContains(trimmed)
            }
            return items.isEmpty ? nil : (section.group, items)
        }
    }

    // Seed `selectedBuff` with each category's configured default the first
    // time a category appears, but only if the buff exists in inventory and
    // the user hasn't already picked something. Pure side-effect on
    // `selectedBuff`; idempotent.
    //
    // Resolution order:
    //   1. Per-category `defaultBuff` on the struct itself (raw buff name).
    //      Only set in-code today by the synthetic tribute/unmapped
    //      constructors using the "" sentinel.
    //   2. Per-subgroup display name from buff-panel-config.json
    //      (key = category display name, e.g. "Copper Mine"), resolved
    //      back to a raw buffName via the live BuffsStore inventory.
    //   3. Static fallback (raw buff name) — only reached for categories
    //      that aren't listed in `subgroups` yet (new building types).
    //
    // "" or a display name not in inventory leaves the row unset so the
    // user opts in manually.
    private func applyDefaults(to snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]) {
        for group in snapshot {
            // Unmapped categories never get a default — user must opt in per row.
            if group.category.group == BuildingGroup.unmapped.rawValue { continue }
            guard selectedBuff[group.category.id] == nil else { continue }

            let raw: String
            if let categoryOverride = group.category.defaultBuff {
                raw = categoryOverride
            } else if let subgroupDisplay = panelConfig
                        .defaultBuffDisplayName(forSubgroup: group.category.displayName) {
                guard let resolved = resolveBuffRaw(displayName: subgroupDisplay) else { continue }
                raw = resolved
            } else {
                raw = Self.fallbackDefaultBuff
            }

            guard buffsStore.item(for: raw) != nil else { continue }
            selectedBuff[group.category.id] = raw
        }
    }

    // Display-name → raw buffName via BuffsStore inventory. Empty string or
    // an unrecognized display name → nil (caller skips seeding the row).
    private func resolveBuffRaw(displayName: String) -> String? {
        guard !displayName.isEmpty else { return nil }
        return buffsStore.uniqueTypes.first { $0.displayLabel == displayName }?.buffName
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
    // The server decrements the stack amount on each call. Buildings already
    // carrying an active buff are skipped — the in-game UI refuses to re-buff
    // a buffed building, and the server would still consume a stack if we did
    // it via our injection. Returned Task lets tests await completion.
    @discardableResult
    func buffAll(group: [BuildingsStore.BuildingItem], buffName: String) -> Task<Void, Never>? {
        guard let buff = buffsStore.item(for: buffName) else { return nil }
        let candidates = group.filter { $0.activeBuff == nil }
        guard !candidates.isEmpty else {
            logger.log("[BuffAll] all \(group.count) buildings already buffed; skipping")
            return nil
        }
        let total = candidates.count
        return bulk.run(items: candidates) { [self] i, building in
            logger.log("[BuffAll] \(i + 1)/\(total) grid=\(building.gridIndex) " +
                       "buff=\(buff.uid1):\(buff.uid2)")
            dispatcher.dispatchBuff(
                buffUid1: buff.uid1,
                buffUid2: buff.uid2,
                targetGrid: building.gridIndex)
            noteBuffDispatched(buffLabel: buff.displayLabel)
        }
    }

    // Coalesces rapid-fire buff dispatches (per-category or master "Buff all")
    // into a single banner that resets after `buffBannerHideDelay` seconds of
    // quiet. Mirrors `SpecialistDispatchCoordinator.noteExplorerDispatched`.
    // Shows the buff display name when a burst is homogenous; drops the
    // label if the master dispatch mixes different buffs across categories,
    // so the banner doesn't strobe.
    private func noteBuffDispatched(buffLabel: String) {
        buffBannerCount += 1
        if buffBannerCount == 1 {
            buffBannerLastBuff = buffLabel
        } else if buffBannerLastBuff != buffLabel {
            buffBannerLastBuff = nil   // mixed burst
        }
        let n = buffBannerCount
        let labelSuffix = buffBannerLastBuff.map { " · \($0)" } ?? ""
        buffBannerText = n == 1
            ? "Building buffed\(labelSuffix)"
            : "\(n) buildings buffed\(labelSuffix)"
        buffBannerHideTask?.cancel()
        let delay = buffBannerHideDelay
        buffBannerHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            self.buffBannerText = nil
            self.buffBannerCount = 0
            self.buffBannerLastBuff = nil
        }
    }

    // Dispatch each group's own `selectedBuff` to its buildings. Groups
    // without a selection (or whose selection is missing from inventory) are
    // skipped, as are buildings that already carry an active buff (see
    // `buffAll`). Returns nil if nothing is dispatchable.
    @discardableResult
    func buffAllGroups(snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]) -> Task<Void, Never>? {
        struct Step { let building: BuildingsStore.BuildingItem; let buff: BuffsStore.BuffItem }
        var steps: [Step] = []
        for group in snapshot {
            // Unmapped categories are excluded from the master "Buff all".
            if group.category.group == BuildingGroup.unmapped.rawValue { continue }
            let name = selectedBuff[group.category.id] ?? ""
            guard !name.isEmpty, let buff = buffsStore.item(for: name) else { continue }
            for b in group.buildings where b.activeBuff == nil {
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
            noteBuffDispatched(buffLabel: step.buff.displayLabel)
        }
    }
}
