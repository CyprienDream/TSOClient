import SwiftUI

struct BuffsPanel: View {
    var buildingsStore: BuildingsStore
    var buffsStore: BuffsStore
    // buffUid1, buffUid2, targetGrid
    var onDispatch: (Int, Int, Int) -> Void

    // Selected buff name per category (keyed by category displayName).
    @State private var selectedBuff: [String: String] = [:]
    // Master picker selection; when changed, overrides every category's selection.
    @State private var masterBuff: String = ""

    struct BuildingCategory: Identifiable {
        var id: String { displayName }
        let displayName: String
        let skinBases: [String]
    }

    // Curated categories shown in the panel. Order is the display order.
    // A category with zero matching buildings is hidden.
    private static let categories: [BuildingCategory] = [
        .init(displayName: "Stone Mason",            skinBases: ["Mason"]),
        .init(displayName: "Granite Mason",          skinBases: ["GraniteMason"]),
        .init(displayName: "Marble Mason",           skinBases: ["MarbleMason"]),
        .init(displayName: "Brewery",                skinBases: ["Brewery"]),
        .init(displayName: "Exotic Wood Cutter",     skinBases: ["ExoticWoodCutter"]),
        .init(displayName: "Exotic Wood Forester",   skinBases: ["ExoticWoodForester"]),
        .init(displayName: "Exotic Wood Sawmill",    skinBases: ["ExoticWoodSawmill"]),
        .init(displayName: "Weaver",                 skinBases: ["Weaver"]),
        .init(displayName: "Homestead",              skinBases: ["Homestead"]),
        .init(displayName: "Elite Stable",           skinBases: ["EliteStable"]),
        .init(displayName: "Stables",                skinBases: ["Stable"]),
        .init(displayName: "Papermill (All)",        skinBases: ["PapermillSimple", "PapermillIntermediate", "PapermillAdvanced"]),
        .init(displayName: "Watermill (Normal + Improved)", skinBases: ["Watermill", "ImprovedWatermill"]),
        .init(displayName: "Platinum Weaponsmith",   skinBases: ["PlatinumWeaponsmith"]),
        .init(displayName: "Finesmith",              skinBases: ["Finesmith", "Elari_Finesmith"]),
        .init(displayName: "Fish Farm",              skinBases: ["FishFarm"]),
        .init(displayName: "Fisherman",              skinBases: ["Fisher"]),
        .init(displayName: "Hunter",                 skinBases: ["Hunter"]),
        .init(displayName: "Deerstalker Hut",        skinBases: ["DeerstalkerHut"]),
        .init(displayName: "Coking Plant",           skinBases: ["CokingPlant"]),
        .init(displayName: "Rabbit Retreat",         skinBases: ["RabbitBreeding"]),
        .init(displayName: "Recycling Manufactory",  skinBases: ["RecyclingManufactory"]),
        .init(displayName: "Butcher (Normal + Improved)", skinBases: ["Butcher", "ImprovedButcher"]),
        .init(displayName: "Gold Tower",             skinBases: ["GoldTower"]),
        .init(displayName: "Mountain Clan Colossus", skinBases: ["MountainClanColossus"]),
        .init(displayName: "Copper Smelter",         skinBases: ["BronzeSmelter"]),
        .init(displayName: "Iron Smelter",           skinBases: ["IronSmelter"]),
        .init(displayName: "Platinum Smelter",       skinBases: ["PlatinumSmelter"]),
        .init(displayName: "Steel Smelter",          skinBases: ["SteelForge"]),
        .init(displayName: "Coinage",                skinBases: ["Coinage"]),
        .init(displayName: "Farm (Normal + Improved)",   skinBases: ["Farm", "ImprovedFarm"]),
        .init(displayName: "Silo (Normal + Improved)",   skinBases: ["silo", "ImprovedSilo"]),
        .init(displayName: "Sunflower Farm",         skinBases: ["SunflowerFarm"]),
        .init(displayName: "Bakery (Normal + Improved)", skinBases: ["Bakery", "ImprovedBakery"]),
        .init(displayName: "Mill (Normal + Improved)",   skinBases: ["Miller", "ImprovedMill"]),
    ]

    private var groups: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])] {
        BuffsPanel.categories.compactMap { category in
            let buildings = buildingsStore.buildings(matchingSkinBases: category.skinBases)
            return buildings.isEmpty ? nil : (category, buildings)
        }
    }

    // Building-specific buffs: productivity buffs for individual buildings,
    // plus RemoveBuff and a seasonal variant. Town-hall area buffs, barracks,
    // adventure buffs, etc. are excluded.
    private var buildingBuffs: [BuffsStore.BuffItem] {
        buffsStore.uniqueTypes.filter { isBuildingBuff($0.buffName) }
    }

    private func isBuildingBuff(_ name: String) -> Bool {
        name.hasPrefix("ProductivityBuff") ||
        name == "RemoveBuff" ||
        name == "HalloweenEvent_Horror"
    }

    var body: some View {
        // Compute once per body invocation so each row reads from the same snapshot.
        let snapshot = groups
        let buffs = buildingBuffs
        let buffsVersion = buffsStore.version
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if buildingsStore.items.isEmpty {
                Text("No buildings loaded.\nZone must be active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else if buffsStore.items.isEmpty {
                Text("No buffs in inventory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                masterRow(buffs: buffs, snapshot: snapshot)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot, id: \.category.id) { group in
                            let sel = selectedBuff[group.category.id] ?? ""
                            BuildingGroupRow(
                                categoryDisplayName: group.category.displayName,
                                buildingsCount: group.buildings.count,
                                buffedCount: group.buildings.reduce(0) { $0 + ($1.activeBuff != nil ? 1 : 0) },
                                availableBuffs: buffs,
                                buffsVersion: buffsVersion,
                                selectedBuff: sel,
                                onSelect: { newName in
                                    selectedBuff[group.category.id] = newName
                                },
                                onBuffAll: {
                                    buffAll(group: group.buildings, buffName: sel)
                                }
                            )
                            .equatable()
                            .padding(.horizontal, 12)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Buffs").font(.headline)
            Spacer()
            if !buffsStore.items.isEmpty {
                Text("\(buffsStore.uniqueTypes.count) types · \(buffsStore.items.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Menu that overrides every visible group's selection when an item is picked,
    // plus a "Buff all" button that fires the selected buff across every group.
    private func masterRow(
        buffs: [BuffsStore.BuffItem],
        snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])]
    ) -> some View {
        let label = masterBuff.isEmpty
            ? "— select buff —"
            : (buffs.first { $0.buffName == masterBuff }?.displayLabel ?? masterBuff)
        let canBuffAll = !masterBuff.isEmpty && buffsStore.totalAmount(for: masterBuff) > 0
        let totalBuildings = snapshot.reduce(0) { $0 + $1.buildings.count }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Override all groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(totalBuildings) buildings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Menu {
                    Button("— select buff —") {
                        masterBuff = ""
                    }
                    ForEach(buffs) { buff in
                        Button(buff.displayLabel) {
                            masterBuff = buff.buffName
                            for group in snapshot {
                                selectedBuff[group.category.id] = buff.buffName
                            }
                        }
                    }
                } label: {
                    Text(label).frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Buff all") {
                    buffAllGroups(snapshot: snapshot, buffName: masterBuff)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canBuffAll)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Dispatch the same buff stack uid to every building in the group.
    // The server decrements the stack amount on each call.
    private func buffAll(group: [BuildingsStore.BuildingItem], buffName: String) {
        guard let buff = buffsStore.item(for: buffName) else { return }
        Task { @MainActor in
            for (i, building) in group.enumerated() {
                print("[BuffAll] \(i + 1)/\(group.count) grid=\(building.gridIndex) buff=\(buff.uid1):\(buff.uid2)")
                onDispatch(buff.uid1, buff.uid2, building.gridIndex)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    // Flatten every visible group's buildings and dispatch the master buff to each.
    private func buffAllGroups(
        snapshot: [(category: BuildingCategory, buildings: [BuildingsStore.BuildingItem])],
        buffName: String
    ) {
        let all = snapshot.flatMap { $0.buildings }
        buffAll(group: all, buffName: buffName)
    }
}

// Equatable so SwiftUI skips re-rendering rows whose visible inputs didn't change.
// Closures and the BuffsStore reference are intentionally ignored in `==`.
private struct BuildingGroupRow: View, Equatable {
    let categoryDisplayName: String
    let buildingsCount: Int
    let buffedCount: Int
    let availableBuffs: [BuffsStore.BuffItem]
    let buffsVersion: Int
    let selectedBuff: String
    let onSelect: (String) -> Void
    let onBuffAll: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.categoryDisplayName == rhs.categoryDisplayName &&
        lhs.buildingsCount      == rhs.buildingsCount &&
        lhs.buffedCount         == rhs.buffedCount &&
        lhs.buffsVersion        == rhs.buffsVersion &&
        lhs.selectedBuff        == rhs.selectedBuff
    }

    private var selectedBuffLabel: String {
        if selectedBuff.isEmpty { return "— select buff —" }
        return availableBuffs.first { $0.buffName == selectedBuff }?.displayLabel ?? selectedBuff
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(categoryDisplayName)
                        .font(.subheadline).bold()
                    Text("\(buildingsCount) buildings")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if buffedCount > 0 {
                    Text("\(buffedCount) buffed")
                        .font(.caption2).bold()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue, in: Capsule())
                }
            }

            HStack(spacing: 6) {
                Menu {
                    Button("— select buff —") { onSelect("") }
                    ForEach(availableBuffs) { buff in
                        Button(buff.displayLabel) { onSelect(buff.buffName) }
                    }
                } label: {
                    Text(selectedBuffLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Buff all") {
                    onBuffAll()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedBuff.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }
}
