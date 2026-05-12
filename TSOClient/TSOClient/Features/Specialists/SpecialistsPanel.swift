import SwiftUI
import Combine

struct SpecialistsPanel: View {
    var store: SpecialistsStore
    var onDispatch: (Int, Int, Int, Int) -> Void  // uid1, uid2, subTaskID, targetGrid

    @State private var filter: String = "All"
    @State private var selectedTasks: [String: Int] = [:]   // specialist id → task code
    @State private var selectedGrids: [String: Int] = [:]   // specialist id → target grid

    private let filters = ["All", "Geologist", "Explorer", "General"]

    var filtered: [SpecialistsStore.SpecialistItem] {
        guard filter != "All" else { return store.items }
        return store.items.filter { $0.specialistType.contains(filter) }
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
                List(filtered) { spec in
                    SpecialistRow(
                        spec: spec,
                        taskCode: Binding(
                            get: { selectedTasks[spec.id] ?? defaultTask(for: spec) },
                            set: { selectedTasks[spec.id] = $0 }
                        ),
                        targetGrid: Binding(
                            get: { selectedGrids[spec.id] ?? 0 },
                            set: { selectedGrids[spec.id] = $0 }
                        ),
                        onDispatch: { subTaskID, targetGrid in
                            onDispatch(spec.uid1, spec.uid2, subTaskID, targetGrid)
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 300)
    }

    private var header: some View {
        Text("Specialists")
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(filters, id: \.self) { f in
                Button(f) { filter = f }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(filter == f ? .accentColor : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func defaultTask(for spec: SpecialistsStore.SpecialistItem) -> Int {
        if spec.specialistType.contains("Geologist") { return GeologistTask.findCoal.rawValue }
        if spec.specialistType.contains("Explorer")  { return ExplorerTask.findTreasure.rawValue }
        return 0
    }
}

struct SpecialistRow: View {
    let spec: SpecialistsStore.SpecialistItem
    @Binding var taskCode: Int
    @Binding var targetGrid: Int
    var onDispatch: (Int, Int) -> Void

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name.isEmpty ? "Specialist" : spec.name)
                        .font(.subheadline).bold()
                    Text("\(spec.specialistType) · Lv \(spec.level)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            if spec.isIdle {
                taskControls
            }
        }
        .padding(.vertical, 4)
        .onReceive(timer) { now = $0 }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if spec.isIdle {
            Text("Idle")
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green, in: Capsule())
        } else if let endMs = spec.taskEndTime {
            let remaining = max(0, endMs / 1000 - now.timeIntervalSince1970)
            Text(formatDuration(remaining))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var taskControls: some View {
        if spec.specialistType.contains("Geologist") {
            HStack {
                Picker("Task", selection: $taskCode) {
                    ForEach(GeologistTask.allCases) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        } else if spec.specialistType.contains("Explorer") {
            HStack {
                Picker("Task", selection: $taskCode) {
                    ForEach(ExplorerTask.allCases) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        } else {
            HStack {
                Text("Task \(taskCode)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                dispatchButton
            }
        }
    }

    private var dispatchButton: some View {
        Button("Dispatch") {
            onDispatch(taskCode, targetGrid)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!spec.isIdle)
    }

    private func formatDuration(_ secs: Double) -> String {
        let s = Int(secs)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, sec)
    }
}
