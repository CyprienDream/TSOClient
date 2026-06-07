import SwiftUI

struct SpecialistsPanel: View {
    var store: SpecialistsStore
    var onDispatch: (Int, Int, TaskCode, Int) -> Void  // uid1, uid2, taskCode, targetGrid

    @State private var filter: SpecialistKind? = nil   // nil = All
    @State private var selectedTasks: [String: TaskCode] = [:]
    @State private var selectedGrids: [String: Int] = [:]
    @State private var bulkGeologistTask: GeologistTask = .findStone
    @State private var bulkExplorerTask: ExplorerTask = .treasureShort

    private let filters: [SpecialistKind?] = [nil, .geologist, .explorer, .general]

    var filtered: [SpecialistsStore.SpecialistItem] {
        guard let kind = filter else { return store.items }
        return store.items.filter { $0.specialistType == kind }
    }

    private var idleInView: [SpecialistsStore.SpecialistItem] {
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
                        playerLevel: store.playerLevel,
                        taskStartedAt: store.taskStartedAt[spec.id],
                        learnedDurations: store.learnedDurations,
                        taskCode: Binding(
                            get: { selectedTasks[spec.id] ?? spec.specialistType.defaultTaskCode },
                            set: { selectedTasks[spec.id] = $0 }
                        ),
                        targetGrid: Binding(
                            get: { selectedGrids[spec.id] ?? 0 },
                            set: { selectedGrids[spec.id] = $0 }
                        ),
                        onDispatch: { tc, grid in
                            onDispatch(spec.uid1, spec.uid2, tc, grid)
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

    // Fires the currently-selected per-row task for every idle Explorer/Geologist
    // in the active filter. Skipped: Generals (need a grid), Unknown (no task set).
    private var bulkBar: some View {
        HStack {
            Text("\(idleInView.count) idle in view")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dispatch all idle") {
                bulkDispatch()
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
                        Picker("", selection: $bulkGeologistTask) {
                            ForEach(GeologistTask.allCases) { t in
                                Text(t.label(forPlayerLevel: store.playerLevel)).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .onChange(of: bulkGeologistTask) { _, new in
                            applyBulkTask(new.taskCode, to: .geologist)
                        }
                    }
                }
                if showExp {
                    HStack {
                        Text("All Explorers:")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $bulkExplorerTask) {
                            ForEach(ExplorerTask.allCases) { t in
                                Text(t.label).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .onChange(of: bulkExplorerTask) { _, new in
                            applyBulkTask(new.taskCode, to: .explorer)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func applyBulkTask(_ code: TaskCode, to kind: SpecialistKind) {
        for spec in store.items where spec.specialistType == kind {
            selectedTasks[spec.id] = code
        }
    }

    private func bulkDispatch() {
        let snapshot = idleInView
        let plan: [(SpecialistsStore.SpecialistItem, TaskCode, Int)] = snapshot.compactMap { spec in
            let tc = selectedTasks[spec.id] ?? spec.specialistType.defaultTaskCode
            guard tc.isAvailable(for: spec, playerLevel: store.playerLevel) else { return nil }
            let grid = selectedGrids[spec.id] ?? 0
            return (spec, tc, grid)
        }
        print("[Bulk] firing \(plan.count) of \(snapshot.count) idle (skipped: \(snapshot.count - plan.count) gated)")
        BulkDispatcher.run(items: plan) { i, item in
            let (spec, tc, grid) = item
            print("[Bulk] \(i + 1)/\(plan.count) uid=\(spec.uid1):\(spec.uid2) at=\(tc.actionType) st=\(tc.subTaskID)")
            onDispatch(spec.uid1, spec.uid2, tc, grid)
        }
    }
}
