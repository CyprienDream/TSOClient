import SwiftUI
import Combine

struct SpecialistsPanel: View {
    var store: SpecialistsStore
    var onDispatch: (Int, Int, TaskCode, Int) -> Void  // uid1, uid2, taskCode, targetGrid

    @State private var filter: String = "All"
    @State private var selectedTasks: [String: TaskCode] = [:]
    @State private var selectedGrids: [String: Int] = [:]
    @State private var bulkGeologistTask: GeologistTask = .findStone
    @State private var bulkExplorerTask: ExplorerTask = .treasureShort

    private let filters = ["All", "Geologist", "Explorer", "General"]

    var filtered: [SpecialistsStore.SpecialistItem] {
        guard filter != "All" else { return store.items }
        return store.items.filter { $0.specialistType == filter }
    }

    private var idleInView: [SpecialistsStore.SpecialistItem] {
        filtered.filter { $0.isIdle && $0.specialistType != "General" && $0.specialistType != "Unknown" }
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
                Button(f) { filter = f }
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
        let showGeo = filter == "All" || filter == "Geologist"
        let showExp = filter == "All" || filter == "Explorer"
        if showGeo || showExp {
            VStack(alignment: .leading, spacing: 4) {
                if showGeo {
                    HStack {
                        Text("All Geologists:")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $bulkGeologistTask) {
                            ForEach(GeologistTask.allCases) { t in
                                Text(taskLabel(t)).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .onChange(of: bulkGeologistTask) { _, new in
                            applyBulkTask(new.taskCode, to: "Geologist")
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
                            applyBulkTask(new.taskCode, to: "Explorer")
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func applyBulkTask(_ code: TaskCode, to type: String) {
        for spec in store.items where spec.specialistType == type {
            selectedTasks[spec.id] = code
        }
    }

    private func taskLabel(_ t: GeologistTask) -> String {
        if t.isAvailable(playerLevel: store.playerLevel) { return t.label }
        return "\(t.label) (lvl \(t.minLevel))"
    }

    // Fire bulk dispatch sequentially with a small inter-call delay so rapid
    // evaluateJavaScript calls don't get reordered / dropped on the WKWebView side,
    // and so each call's outbound auth/seq capture has time to settle before the next.
    private func bulkDispatch() {
        let snapshot = idleInView
        let plan: [(SpecialistsStore.SpecialistItem, TaskCode, Int)] = snapshot.compactMap { spec in
            let tc = selectedTasks[spec.id] ?? defaultTask(for: spec)
            guard isTaskAvailable(tc, for: spec) else { return nil }
            let grid = selectedGrids[spec.id] ?? 0
            return (spec, tc, grid)
        }
        print("[Bulk] firing \(plan.count) of \(snapshot.count) idle (skipped: \(snapshot.count - plan.count) gated)")
        Task { @MainActor in
            for (i, item) in plan.enumerated() {
                let (spec, tc, grid) = item
                print("[Bulk] \(i + 1)/\(plan.count) uid=\(spec.uid1):\(spec.uid2) at=\(tc.actionType) st=\(tc.subTaskID)")
                onDispatch(spec.uid1, spec.uid2, tc, grid)
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            }
        }
    }

    private func defaultTask(for spec: SpecialistsStore.SpecialistItem) -> TaskCode {
        if spec.specialistType == "Geologist" { return GeologistTask.findStone.taskCode }
        if spec.specialistType == "Explorer"  { return ExplorerTask.treasureShort.taskCode }
        return generalStarMenuCode
    }

    private func isTaskAvailable(_ code: TaskCode, for spec: SpecialistsStore.SpecialistItem) -> Bool {
        if spec.specialistType == "Geologist",
           let task = GeologistTask(rawValue: code.subTaskID), code.actionType == 0 {
            return task.isAvailable(playerLevel: store.playerLevel)
        }
        if spec.specialistType == "Explorer",
           let task = ExplorerTask.allCases.first(where: { $0.taskCode == code }) {
            return task.isAvailable(skills: spec.skills)
        }
        return true
    }
}

struct SpecialistRow: View {
    let spec: SpecialistsStore.SpecialistItem
    let playerLevel: Int?
    let taskStartedAt: Date?
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
                    Text(spec.displayPrimary)
                        .font(.subheadline).bold()
                    if spec.hasDistinctSecondary {
                        Text(spec.displaySubtype)
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        } else if let startedAt = taskStartedAt {
            // collectedTime = elapsed ms (counts up), so taskStartedAt is back-calculated
            // to the real start. Display elapsed since start; total duration is not in the
            // AMF data — it comes from game-client config — so remaining can't be shown.
            let elapsed = now.timeIntervalSince(startedAt)
            Text(formatDuration(max(0, elapsed)))
                .font(.caption2)
                .foregroundStyle(.orange)
                .monospacedDigit()
        } else {
            Text("Busy")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var taskControls: some View {
        if spec.specialistType == "Geologist" {
            HStack {
                Picker("Task", selection: $taskCode) {
                    ForEach(GeologistTask.allCases) { t in
                        Text(taskLabel(t)).tag(t.taskCode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        } else if spec.specialistType == "Explorer" {
            HStack {
                Picker("Task", selection: $taskCode) {
                    ForEach(ExplorerTask.allCases) { t in
                        if t.isAvailable(skills: spec.skills) {
                            Text(t.label).tag(t.taskCode)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        } else if spec.specialistType == "General" {
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

    private func taskLabel(_ t: GeologistTask) -> String {
        if t.isAvailable(playerLevel: playerLevel) { return t.label }
        return "\(t.label) (lvl \(t.minLevel))"
    }

    private var dispatchButton: some View {
        Button("Dispatch") {
            onDispatch(taskCode, targetGrid)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!spec.isIdle || !isCurrentTaskAvailable)
    }

    private var isCurrentTaskAvailable: Bool {
        if spec.specialistType == "Geologist",
           let task = GeologistTask(rawValue: taskCode.subTaskID), taskCode.actionType == 0 {
            return task.isAvailable(playerLevel: playerLevel)
        }
        if spec.specialistType == "Explorer",
           let task = ExplorerTask.allCases.first(where: { $0.taskCode == taskCode }) {
            return task.isAvailable(skills: spec.skills)
        }
        return true
    }

    private func formatDuration(_ secs: Double) -> String {
        let s = Int(secs)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %dh %02dm", d, h, m) }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, sec)
    }
}
