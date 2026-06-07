import SwiftUI
import Combine

struct SpecialistRow: View {
    let spec: SpecialistsStore.SpecialistItem
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
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            if let key = spec.durationKey,
               let learnedMs = learnedDurations[key] {
                // Known duration from a previous completion — show remaining countdown.
                let remaining = max(0, Double(learnedMs) / 1000.0 - elapsed)
                if remaining <= 0 {
                    Text("Done?")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(DurationFormatter.format(remaining))
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                // No learned duration yet — show elapsed (orange) as honest fallback.
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
                        if t.isAvailable(skills: spec.skills) {
                            Text(t.label).tag(t.taskCode)
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
}
