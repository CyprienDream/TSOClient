import Foundation
import Observation

// View-model for the BuffsPanel. Owns per-category buff selection state and
// the bulk-buff dispatch loops.
@Observable
final class BuffDispatchCoordinator {
    // Selected buff name per category (keyed by category.id). Zone-context
    // scoped: when at home, reads/writes to `homeSelectedBuff` which is
    // persisted through `defaults`. When visiting a friend (or in an
    // adventure), reads/writes to `friendSelectedBuff` which is in-memory
    // only — reset on every entry into non-home context and seeded to Fish
    // Platter so a quick friend-visit buff doesn't burn through our home
    // stacks. On return to home the persisted JSON is reloaded, so any
    // tweaks the user made while visiting are discarded.
    var selectedBuff: [String: String] = [:] {
        didSet {
            if zoneContext == "home" {
                homeSelectedBuff = selectedBuff
                defaults.set(selectedBuff, forKey: Keys.selectedBuff)
            } else {
                friendSelectedBuff = selectedBuff
            }
        }
    }
    // Backing maps for each context. Only `homeSelectedBuff` is persisted.
    private var homeSelectedBuff: [String: String] = [:]
    private var friendSelectedBuff: [String: String] = [:]
    // Current zone context, driven by ZoneContextHandler. Swapping this
    // stashes the outgoing map and loads the incoming one; a friend/adventure
    // transition resets the in-memory map so `applyDefaults` reseeds every
    // category to `friendContextDefaultBuff`.
    var zoneContext: String = "home" {
        willSet {
            if zoneContext == "home" {
                homeSelectedBuff = selectedBuff
            } else {
                friendSelectedBuff = selectedBuff
            }
        }
        didSet {
            guard oldValue != zoneContext else { return }
            if zoneContext == "home" {
                let persisted = defaults.dictionary(forKey: Keys.selectedBuff) ?? [:]
                homeSelectedBuff = persisted.compactMapValues { $0 as? String }
                selectedBuff = homeSelectedBuff
            } else {
                friendSelectedBuff = [:]
                selectedBuff = friendSelectedBuff
            }
        }
    }
    // Public entry point used by ZoneContextHandler (see BuffZoneContextSink
    // conformance at the bottom of this file).
    func setZoneContext(_ context: String) { zoneContext = context }
    // Selected zone-wide buff (populated from `zoneBuffs`). Dispatch is not
    // wired yet — the server opcode for zone-buff application is unknown.
    // Not persisted across launches: zone buffs are high-value and should be
    // a deliberate pick each session.
    var selectedZoneBuff: String = ""
    // When true, every fresh BUILDINGS payload triggers `buffAllGroups` with
    // the current per-category selections. Buildings already carrying an
    // active buff are skipped by the existing filter, so this is effectively
    // a "re-buff on expiry" loop: when a buff drops off server-side the next
    // BUILDINGS inbound will show activeBuff=null and the sweep fires on it.
    // Setting the flag to true also kicks off an immediate sweep so the user
    // doesn't have to wait for the next zone reload.
    var autoBuffLoopEnabled: Bool = false {
        didSet {
            defaults.set(autoBuffLoopEnabled, forKey: Keys.autoBuffLoopEnabled)
            if autoBuffLoopEnabled, !oldValue {
                lastAutoBuffSweep = runAutoBuffSweep()
            }
            if !autoBuffLoopEnabled, oldValue {
                cancelAllPendingReBuffs()
            }
        }
    }
    private(set) var lastAutoBuffSweep: Task<Void, Never>?
    // Per-building wake timers, keyed by BuildingItem.id ("uid1:uid2").
    // Armed when a buff is dispatched and we have a learned duration for
    // that buff name; fires `reBuffBuilding(uid:)` on wake.
    private(set) var pendingReBuffTasks: [String: Task<Void, Never>] = [:]
    // Slack added to the learned duration before waking. Server-side expiry
    // may lag a few seconds past the learned value; the sweep will skip the
    // building if it's still buffed when we wake.
    var autoReBuffBuffer: TimeInterval = 15

    private enum Keys {
        static let selectedBuff        = "buffs.selectedBuff"
        static let autoBuffLoopEnabled = "buffs.autoBuffLoopEnabled"
    }

    // Transient banner surfaced by BuffsPanel when buildings are buffed
    // (per-category bulk or auto-loop sweep). Mirrors the specialist
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
    private let defaults: KeyValueStore
    private let learner: BuffDurationLearner

    init(buffsStore: BuffsStore,
         buildingsStore: BuildingsStore,
         dispatcher: BuffDispatchPort,
         classifier: BuffCategoryClassifier = .default,
         categoryRegistry: BuildingCategoryRegistry = .default,
         panelConfig: BuffPanelConfig = .default,
         naming: NamingRegistry = .default,
         bulk: BulkDispatching = BulkDispatcher.default,
         logger: Logger = ConsoleLogger(),
         defaults: KeyValueStore = UserDefaultsKeyValueStore(),
         learner: BuffDurationLearner? = nil) {
        self.buffsStore = buffsStore
        self.buildingsStore = buildingsStore
        self.dispatcher = dispatcher
        self.classifier = classifier
        self.categoryRegistry = categoryRegistry
        self.panelConfig = panelConfig
        self.naming = naming
        self.bulk = bulk
        self.logger = logger
        self.defaults = defaults
        self.learner = learner ?? BuffDurationLearner(defaults: defaults, logger: logger)
        if let raw = defaults.dictionary(forKey: Keys.selectedBuff) {
            let loaded = raw.compactMapValues { $0 as? String }
            self.homeSelectedBuff = loaded
            self.selectedBuff = loaded
        }
        self.autoBuffLoopEnabled = defaults.bool(forKey: Keys.autoBuffLoopEnabled)
    }

    // Public entry point for BuildingsHandler. Observes current buildings so
    // the learner can resolve any tracked dispatches whose buffs have
    // expired, then fires `buffAllGroups` with the current per-category
    // selections when the loop is enabled. Observation runs regardless of
    // the toggle so learned durations keep accumulating even when auto-loop
    // is off (e.g., if the user manually clicked "Buff all" earlier).
    @discardableResult
    func runAutoBuffSweep() -> Task<Void, Never>? {
        learner.observe(buildings: buildingsStore.items)
        guard autoBuffLoopEnabled else { return nil }
        return buffAllGroups(snapshot: groups)
    }

    // Called after every successful dispatcher.dispatchBuff invocation.
    // Hands the (uid, buffName, now) tuple to the learner and, if the loop
    // is on and the learner has seen this buff expire before, arms a
    // per-building wake Task at now + learnedDuration + autoReBuffBuffer.
    // Previous wake for the same uid is cancelled first so back-to-back
    // dispatches don't accumulate timers.
    private func trackAndMaybeSchedule(building: BuildingsStore.BuildingItem,
                                        buffName: String) {
        let now = Date()
        let uid = building.id
        learner.recordDispatch(uidKey: uid, buffName: buffName, at: now)
        // At dispatch time we don't yet know the applianceMode the server
        // will assign — pass nil and let the learner's fallback chain pick
        // the best estimate: any-mode bucket first, then max across modes.
        // When the BUILDINGS payload echoes the buff back, the learner will
        // latch the mode and the NEXT re-fire for this uid (after the wake
        // fires `fireReBuff`, which calls back into this method) can benefit
        // from a mode-specific duration if we have one.
        guard autoBuffLoopEnabled,
              let duration = learner.learnedDuration(for: buffName,
                                                     applianceMode: nil) else { return }
        let wakeIn = max(0, duration + autoReBuffBuffer)
        pendingReBuffTasks[uid]?.cancel()
        pendingReBuffTasks[uid] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wakeIn * 1_000_000_000))
            if Task.isCancelled { return }
            self?.fireReBuff(uid: uid)
        }
    }

    // Wake-body, extracted so tests can drive the re-buff path without
    // waiting on a real Task.sleep. On wake: check the auto-loop is still
    // on, the building still exists, it isn't buffed/paused/unknown, and
    // its category still has a buff selected. Then dispatch a single buff.
    // Uses the category's CURRENT `selectedBuff` (not the originally-
    // dispatched one), matching the "Use current selection" wake behavior
    // the user specified — a mid-session selector change takes effect at
    // the next re-buff.
    func fireReBuff(uid: String) {
        pendingReBuffTasks.removeValue(forKey: uid)
        guard autoBuffLoopEnabled else { return }
        guard let building = buildingsStore.items.first(where: { $0.id == uid }) else { return }
        guard building.activeBuff == nil, !building.paused else { return }
        guard let category = category(for: building) else { return }
        let buffName = selectedBuff[category.id] ?? ""
        guard !buffName.isEmpty, let buff = buffsStore.item(for: buffName) else { return }
        logger.log("[AutoBuff] timer wake — re-buffing uid=\(uid) grid=\(building.gridIndex) buff=\(buffName)")
        dispatcher.dispatchBuff(
            buffUid1: buff.uid1,
            buffUid2: buff.uid2,
            targetGrid: building.gridIndex)
        noteBuffDispatched(buffLabel: buff.displayLabel)
        trackAndMaybeSchedule(building: building, buffName: buffName)
    }

    // Reverse-lookup from a building to the category it belongs to. Matches
    // the existing `groups` resolution rule — a category owns a building
    // iff its `skinBases` contains the building's skinBase. Returns nil
    // when the building is in an Unmapped/synthetic category (those never
    // participate in auto-loop re-fires).
    private func category(for building: BuildingsStore.BuildingItem) -> BuildingCategory? {
        categoryRegistry.categories.first { $0.skinBases.contains(building.skinBase) }
    }

    // Cancels every pending re-buff Task. Called when the user turns the
    // auto-loop off. Avoid relying on Task.isCancelled checks alone —
    // explicit cancel + map clear prevents leaked references.
    private func cancelAllPendingReBuffs() {
        for (_, t) in pendingReBuffTasks { t.cancel() }
        pendingReBuffTasks.removeAll()
    }

    var buildingBuffs: [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter { classifier.isBuildingBuff($0.buffName) }
    }

    // Zone buffs are listed in their own dropdown at the top of the panel
    // and dispatched via a separate opcode (TBD — see BuffZoneDispatch note
    // in CLAUDE.md). Filtered out of `buildingBuffs` by the classifier so
    // they never leak into per-row dropdowns.
    var zoneBuffs: [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter { classifier.isZoneBuff($0.buffName) }
    }

    // Returns the subset of `buildingBuffs` that is eligible for a given
    // building category. Backs the per-row dropdown filter so a Barracks
    // row only lists Recruiting buffs, a Gold-Mine row only lists Gold
    // Fever (plus any workyard-generic buffs), etc. Threads both the group
    // (coarse prefix scope) and skinBases (per-name override) through to
    // the classifier so Step 2 restrictions (Damascene Hammer only on
    // Weaponsmiths, etc.) take effect.
    func buildingBuffs(for category: BuildingCategory) -> [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter {
            classifier.appliesTo(
                buff: $0.buffName,
                buildingGroup: category.group ?? "",
                skinBases: category.skinBases)
        }
    }

    // Fallback for any category lacking an explicit defaultBuff.
    private static let fallbackDefaultBuff = "ProductivityBuffLvl300"
    // Seeded for every category when visiting a friend / in an adventure.
    // Fish Platter (ProductivityBuffLvl1) is the cheapest productivity buff —
    // we don't want to spend premium buffs on someone else's buildings.
    static let friendContextDefaultBuff = "ProductivityBuffLvl1"

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
            if zoneContext != "home" {
                // Friend/adventure: always default every category to Fish
                // Platter, bypassing home's per-subgroup defaults. User can
                // still override per-row mid-visit.
                raw = Self.friendContextDefaultBuff
            } else if let categoryOverride = group.category.defaultBuff {
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

    // Dispatch the same buff stack uid to every building in the group.
    // The server decrements the stack amount on each call. Buildings already
    // carrying an active buff are skipped — the in-game UI refuses to re-buff
    // a buffed building, and the server would still consume a stack if we did
    // it via our injection. Paused buildings (production off) are also skipped:
    // the buff would apply but produce no output. Returned Task lets tests
    // await completion.
    @discardableResult
    func buffAll(group: [BuildingsStore.BuildingItem], buffName: String) -> Task<Void, Never>? {
        guard let buff = buffsStore.item(for: buffName) else { return nil }
        let candidates = group.filter { $0.activeBuff == nil && !$0.paused }
        guard !candidates.isEmpty else {
            logger.log("[BuffAll] all \(group.count) buildings already buffed or paused; skipping")
            return nil
        }
        let total = candidates.count
        return bulk.run(items: candidates) { [self] i, building in
            logger.log("[BuffAll] \(i + 1)/\(total) grid=\(building.gridIndex) " +
                       "buff=\(buffName) uid=\(buff.uid1):\(buff.uid2)")
            dispatcher.dispatchBuff(
                buffUid1: buff.uid1,
                buffUid2: buff.uid2,
                targetGrid: building.gridIndex)
            noteBuffDispatched(buffLabel: buff.displayLabel)
            trackAndMaybeSchedule(building: building, buffName: buffName)
        }
    }

    // Coalesces rapid-fire buff dispatches (per-category or auto-loop sweep)
    // into a single banner that resets after `buffBannerHideDelay` seconds of
    // quiet. Mirrors `SpecialistDispatchCoordinator.noteExplorerDispatched`.
    // Shows the buff display name when a burst is homogenous; drops the
    // label if the sweep mixes different buffs across categories,
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
        struct Step {
            let building: BuildingsStore.BuildingItem
            let buff: BuffsStore.BuffItem
            let buffName: String
        }
        var steps: [Step] = []
        for group in snapshot {
            // Unmapped categories are excluded from the auto-loop sweep.
            if group.category.group == BuildingGroup.unmapped.rawValue { continue }
            let name = selectedBuff[group.category.id] ?? ""
            guard !name.isEmpty, let buff = buffsStore.item(for: name) else { continue }
            for b in group.buildings where b.activeBuff == nil && !b.paused {
                steps.append(Step(building: b, buff: buff, buffName: name))
            }
        }
        guard !steps.isEmpty else { return nil }
        let total = steps.count
        return bulk.run(items: steps) { [self] i, step in
            logger.log("[BuffAll] \(i + 1)/\(total) grid=\(step.building.gridIndex) " +
                       "buff=\(step.buffName) uid=\(step.buff.uid1):\(step.buff.uid2)")
            dispatcher.dispatchBuff(
                buffUid1: step.buff.uid1,
                buffUid2: step.buff.uid2,
                targetGrid: step.building.gridIndex)
            noteBuffDispatched(buffLabel: step.buff.displayLabel)
            trackAndMaybeSchedule(building: step.building, buffName: step.buffName)
        }
    }
}

extension BuffDispatchCoordinator: BuffZoneContextSink {}
