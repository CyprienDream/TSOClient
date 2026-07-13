import SwiftUI

struct BuffsPanel: View {
    var buildingsStore: BuildingsStore
    var buffsStore: BuffsStore
    var coordinator: BuffDispatchCoordinator

    @State private var searchText: String = ""

    var body: some View {
        // Compute once per body invocation so each row reads from the same snapshot.
        let snapshot = coordinator.groups
        let buffs = coordinator.buildingBuffs
        let buffsVersion = buffsStore.version
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespaces)
        let visibleSections = coordinator.filteredGroupedSnapshot(matching: trimmedQuery)
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
                searchField
                Divider()
                if visibleSections.isEmpty {
                    Text("No buildings match \u{201C}\(trimmedQuery)\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleSections, id: \.group) { section in
                                SectionHeader(group: section.group, count: section.items.count)
                                ForEach(section.items, id: \.category.id) { group in
                                    let sel = coordinator.selectedBuff[group.category.id] ?? ""
                                    BuildingGroupRow(
                                        categoryDisplayName: group.category.displayName,
                                        buildingsCount: group.buildings.count,
                                        buffedCount: group.buildings.reduce(0) { $0 + ($1.activeBuff != nil ? 1 : 0) },
                                        availableBuffs: buffs,
                                        buffsVersion: buffsVersion,
                                        selectedBuff: sel,
                                        onSelect: { newName in
                                            coordinator.selectedBuff[group.category.id] = newName
                                        },
                                        onBuffAll: {
                                            coordinator.buffAll(group: group.buildings, buffName: sel)
                                        }
                                    )
                                    .equatable()
                                    .padding(.horizontal, 12)
                                    .background(section.group.tint.opacity(0.05))
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 320)
        .overlay(alignment: .top) {
            if let text = coordinator.buffBannerText {
                BuffDispatchBanner(text: text)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.buffBannerText)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search buildings", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
        let label = coordinator.masterBuff.isEmpty
            ? "— select buff —"
            : (buffs.first { $0.buffName == coordinator.masterBuff }?.displayLabel ?? coordinator.masterBuff)
        let totalBuildings = snapshot.reduce(0) { acc, entry in
            entry.category.group == BuildingGroup.unmapped.rawValue ? acc : acc + entry.buildings.count
        }
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
                        coordinator.selectMasterBuff("", across: snapshot)
                    }
                    ForEach(buffs) { buff in
                        Button(buff.displayLabel) {
                            coordinator.selectMasterBuff(buff.buffName, across: snapshot)
                        }
                    }
                } label: {
                    Text(label).frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Buff all") {
                    coordinator.buffAllGroups(snapshot: snapshot)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// Small tinted bar that announces each building-group bucket.
private struct SectionHeader: View {
    let group: BuildingGroup
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(group.tint)
                .frame(width: 8, height: 8)
            Text(group.displayName.uppercased())
                .font(.caption2).bold()
                .foregroundStyle(group.tint)
                .kerning(0.5)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(group.tint.opacity(0.12))
    }
}

// Equatable so SwiftUI skips re-rendering rows whose visible inputs didn't change.
// Closures and store references are intentionally ignored in `==`.
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

// Transient banner shown at the top of BuffsPanel when a bulk buff dispatch
// runs. Mirrors ExplorerDispatchBanner in SpecialistsPanel. Coalescing +
// hide timing are managed by BuffDispatchCoordinator.
private struct BuffDispatchBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
            Text(text).font(.caption).bold()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.blue.opacity(0.92))
        )
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}
