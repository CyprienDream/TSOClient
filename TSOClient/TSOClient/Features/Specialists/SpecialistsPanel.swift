import SwiftUI

struct SpecialistsPanel: View {
    var store: SpecialistsStore
    var coordinator: SpecialistDispatchCoordinator

    @State private var filter: SpecialistKind? = nil   // nil = All

    private let filters: [SpecialistKind?] = [nil, .geologist, .explorer, .general]

    var filtered: [SpecialistItem] {
        let base = filter.map { kind in store.items.filter { $0.specialistType == kind } } ?? store.items
        let formatter = store.formatter
        return base.sorted { lhs, rhs in
            formatter.displayPrimary(for: lhs)
                .localizedCaseInsensitiveCompare(formatter.displayPrimary(for: rhs)) == .orderedAscending
        }
    }

    private var idleInView: [SpecialistItem] {
        filtered.filter { $0.isIdle && $0.specialistType != .general && $0.specialistType != .unknown }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterChips
            Divider()
            if store.items.isEmpty {
                Text("No specialists loaded.\nZone must be active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                bulkBar
                bulkTaskPickers
                Divider()
                List(filtered) { spec in
                    SpecialistRow(
                        spec: spec,
                        formatter: store.formatter,
                        playerLevel: store.playerLevel,
                        taskStartedAt: store.taskStartedAt[spec.id],
                        learnedDurations: store.learnedDurations,
                        taskCode: Binding(
                            get: { coordinator.resolvedTaskCode(for: spec) },
                            set: { coordinator.selectedTasks[spec.id] = $0 }
                        ),
                        targetGrid: Binding(
                            get: { coordinator.resolvedTargetGrid(for: spec) },
                            set: { coordinator.selectedGrids[spec.id] = $0 }
                        ),
                        onDispatch: { tc, grid in
                            coordinator.dispatchOne(spec: spec, taskCode: tc, targetGrid: grid)
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Specialists").font(.headline)
            Spacer()
            if let lvl = store.playerLevel {
                Text("Lvl \(lvl)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(filters, id: \.self) { f in
                Button(f?.rawValue ?? "All") { filter = f }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(filter == f ? .accentColor : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var bulkBar: some View {
        HStack {
            Text("\(idleInView.count) idle in view")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dispatch all idle") {
                coordinator.bulkDispatch(idleSpecialists: idleInView)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(idleInView.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // Per-subcategory bulk-task selectors. Picking a task here propagates it to
    // every spec of that subcategory (regardless of current filter), so the
    // individual row pickers all show the chosen task.
    @ViewBuilder
    private var bulkTaskPickers: some View {
        let showGeo = filter == nil || filter == .geologist
        let showExp = filter == nil || filter == .explorer
        if showGeo || showExp {
            VStack(alignment: .leading, spacing: 4) {
                if showGeo {
                    HStack {
                        Text("All Geologists:")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { coordinator.bulkGeologistTask },
                            set: { new in
                                coordinator.bulkGeologistTask = new
                                coordinator.applyBulkTask(new.taskCode, to: .geologist)
                            }
                        )) {
                            ForEach(GeologistTask.allCases) { t in
                                Text(t.label(forPlayerLevel: store.playerLevel)).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }
                if showExp {
                    HStack {
                        Text("All Explorers:")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { coordinator.bulkExplorerTask },
                            set: { new in
                                coordinator.bulkExplorerTask = new
                                coordinator.applyBulkTask(new.taskCode, to: .explorer)
                            }
                        )) {
                            ForEach(ExplorerTask.allCases) { t in
                                Text(t.label).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
