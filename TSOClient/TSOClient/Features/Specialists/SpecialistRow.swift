import SwiftUI
import Combine

struct SpecialistRow: View {
    let spec: SpecialistItem
    let formatter: SpecialistDisplayFormatter
    let playerLevel: Int?
    let taskStartedAt: Date?
    let learnedDurations: [String: Int]
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
                    Text(formatter.displayPrimary(for: spec))
                        .font(.subheadline).bold()
                    if formatter.hasDistinctSecondary(for: spec) {
                        Text(formatter.displaySubtype(for: spec))
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
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            // Prefer the registry estimate (uses subtype multiplier + skill effects).
            // Fall back to learnedDurations for non-Explorer specialists. Fall back to
            // elapsed (orange) if neither source has data.
            let predicted: Double? = {
                if let est = ExplorerDurationRegistry.estimate(
                    task: TaskCode(actionType: spec.taskActionType ?? -1,
                                   subTaskID: spec.taskSubTaskId ?? -1),
                    subTypeId: spec.subTypeId,
                    skills: spec.skills) {
                    return est
                }
                if let key = spec.durationKey, let learnedMs = learnedDurations[key] {
                    return Double(learnedMs) / 1000.0
                }
                return nil
            }()
            if let total = predicted {
                let remaining = max(0, total - elapsed)
                if remaining <= 0 {
                    Text("Done?")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(DurationFormatter.format(remaining))
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text(DurationFormatter.format(elapsed))
                    .font(.caption2).foregroundStyle(.orange)
                    .monospacedDigit()
            }
        } else {
            Text("Busy")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var taskControls: some View {
        switch spec.specialistType {
        case .geologist:
            HStack {
                Picker("Task", selection: $taskCode) {
                    ForEach(GeologistTask.allCases) { t in
                        Text(t.label(forPlayerLevel: playerLevel)).tag(t.taskCode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        case .explorer:
            HStack {
                Picker("Task", selection: $taskCode) {
                    ForEach(ExplorerTask.allCases) { t in
                        if t.isAvailable(skillIDs: spec.skills.map(\.id)) {
                            Text(labelWithEstimate(t)).tag(t.taskCode)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                dispatchButton
            }
        case .general:
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
        case .unknown:
            Text("Unknown type — reload zone to repopulate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dispatchButton: some View {
        Button("Dispatch") {
            onDispatch(taskCode, targetGrid)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!spec.isIdle || !taskCode.isAvailable(for: spec, playerLevel: playerLevel))
    }

    private func labelWithEstimate(_ t: ExplorerTask) -> String {
        guard let est = ExplorerDurationRegistry.estimate(
            task: t.taskCode, subTypeId: spec.subTypeId, skills: spec.skills)
        else { return t.label }
        return "\(t.label) — \(DurationFormatter.format(est))"
    }
}
