import SwiftUI

struct BuffsPanel: View {
    var buildingsStore: BuildingsStore
    var buffsStore: BuffsStore
    var coordinator: BuffDispatchCoordinator

    @State private var searchText: String = ""

    var body: some View {
        // Compute once per body invocation so each row reads from the same snapshot.
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
                autoLoopToggle
                zoneBuffsRow
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
                                    let scoped = coordinator.buildingBuffs(for: group.category)
                                    BuildingGroupRow(
                                        categoryDisplayName: group.category.displayName,
                                        buildingsCount: group.buildings.count,
                                        buffedCount: group.buildings.reduce(0) { $0 + ($1.activeBuff != nil ? 1 : 0) },
                                        pausedCount: group.buildings.reduce(0) { $0 + ($1.paused ? 1 : 0) },
                                        availableBuffs: scoped,
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

    // Auto-buff loop toggle. Turning it on fires an immediate sweep; from
    // then on every inbound BUILDINGS payload re-runs `buffAllGroups`, so a
    // buff that drops off server-side gets re-applied on the next update
    // (activeBuff flips from a name back to nil, passing the skip filter).
    private var autoLoopToggle: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { coordinator.autoBuffLoopEnabled },
                set: { coordinator.autoBuffLoopEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-buff loop").font(.caption).bold()
                    Text("Reapplies selections when buffs expire")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

    // Zone-wide buffs are dispatched via a separate server opcode (TBD —
    // we don't yet have the wire format, so Apply is disabled). The dropdown
    // is surfaced at the top so the user can see what zone buffs they own
    // and pick one for when dispatch lands. Once the opcode is captured
    // (sniff an in-game zone-buff application), replace the disabled state
    // with a real call into the coordinator.
    @ViewBuilder
    private var zoneBuffsRow: some View {
        let zoneBuffs = coordinator.zoneBuffs
        if !zoneBuffs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Zone buffs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(zoneBuffs.count) available")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Menu {
                        Button("— select zone buff —") {
                            coordinator.selectedZoneBuff = ""
                        }
                        ForEach(zoneBuffs) { buff in
                            Button(buff.displayLabel) {
                                coordinator.selectedZoneBuff = buff.buffName
                            }
                        }
                    } label: {
                        let label = coordinator.selectedZoneBuff.isEmpty
                            ? "— select zone buff —"
                            : (zoneBuffs.first { $0.buffName == coordinator.selectedZoneBuff }?.displayLabel
                                ?? coordinator.selectedZoneBuff)
                        Text(label).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button("Apply") { /* TODO: wire zone-buff dispatch */ }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(true)
                        .help("Zone-buff dispatch not yet wired — need to capture the server opcode from an in-game application.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
    let pausedCount: Int
    let availableBuffs: [BuffsStore.BuffItem]
    let buffsVersion: Int
    let selectedBuff: String
    let onSelect: (String) -> Void
    let onBuffAll: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.categoryDisplayName == rhs.categoryDisplayName &&
        lhs.buildingsCount      == rhs.buildingsCount &&
        lhs.buffedCount         == rhs.buffedCount &&
        lhs.pausedCount         == rhs.pausedCount &&
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
                if pausedCount > 0 {
                    Text("\(pausedCount) asleep")
                        .font(.caption2).bold()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                        .help("Buildings with production paused — skipped by buff dispatch")
                }
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
