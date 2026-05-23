import SwiftUI
import Combine

struct SpecialistsPanel: View {
    var store: SpecialistsStore
    var onDispatch: (Int, Int, TaskCode, Int) -> Void  // uid1, uid2, taskCode, targetGrid

    @State private var filter: String = "All"
    @State private var selectedTasks: [String: TaskCode] = [:]
    @State private var selectedGrids: [String: Int] = [:]

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
                        onDispatch: { tc, grid in
                            onDispatch(spec.uid1, spec.uid2, tc, grid)
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

    private func defaultTask(for spec: SpecialistsStore.SpecialistItem) -> TaskCode {
        if spec.specialistType.contains("Geologist") { return GeologistTask.findStone.taskCode }
        if spec.specialistType.contains("Explorer")  { return ExplorerTask.treasureShort.taskCode }
        return generalStarMenuCode
    }
}

struct SpecialistRow: View {
    let spec: SpecialistsStore.SpecialistItem
    @Binding var taskCode: TaskCode
    @Binding var targetGrid: Int
    var onDispatch: (TaskCode, Int) -> Void

    @State private var now = Date()
    @State private var gridText: String = "0"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name.isEmpty ? spec.specialistType : spec.name)
                        .font(.subheadline).bold()
                    Text(spec.specialistType)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            taskControls
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
                        Text(t.label).tag(t.taskCode)
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
                        Text(t.label).tag(t.taskCode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        } else if spec.specialistType.contains("General") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Grid:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $gridText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.caption)
                        .onChange(of: gridText) { _, v in
                            targetGrid = Int(v) ?? 0
                        }
                    Spacer()
                    Button("Send to Star") {
                        onDispatch(generalStarMenuCode, targetGrid)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } else {
            Text("Unknown type '\(spec.specialistType)' — reload zone to repopulate.")
                .font(.caption).foregroundStyle(.secondary)
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
