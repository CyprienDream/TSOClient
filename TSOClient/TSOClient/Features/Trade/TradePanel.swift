import SwiftUI

struct TradePanel: View {
    var recipientsStore: RecipientsStore
    var resourcesStore: ResourcesStore
    var coordinator: TradeCoordinator

    var body: some View {
        let recipients = recipientsStore.recipients
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if recipients.isEmpty {
                placeholder
            } else {
                form(recipients: recipients)
            }
            Spacer()
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Trade").font(.headline)
            Spacer()
            if !recipientsStore.recipients.isEmpty {
                Text("\(recipientsStore.recipients.count) players")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholder: some View {
        Text("Waiting for friends list and guild roster…\nOpen the in-game social tab if it doesn't arrive.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding()
    }

    private func form(recipients: [RecipientsStore.Recipient]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            recipientRow(recipients: recipients)
            resourceRow(title: "Offer",
                        resourceBinding: Binding(
                            get: { coordinator.offerResource },
                            set: { coordinator.offerResource = $0 }),
                        amountBinding: Binding(
                            get: { coordinator.offerAmount },
                            set: { coordinator.offerAmount = $0 }))
            resourceRow(title: "Ask",
                        resourceBinding: Binding(
                            get: { coordinator.costsResource },
                            set: { coordinator.costsResource = $0 }),
                        amountBinding: Binding(
                            get: { coordinator.costsAmount },
                            set: { coordinator.costsAmount = $0 }))
            sendRow
        }
        .padding(12)
    }

    private func recipientRow(recipients: [RecipientsStore.Recipient]) -> some View {
        let selected = recipientsStore.recipient(id: coordinator.selectedRecipientID)
        let label = selected.map { display($0) }
            ?? "(id \(coordinator.selectedRecipientID))"
        let options = recipients.map {
            SearchableMenu<Int>.Option(id: $0.userID, title: display($0))
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recipient").font(.caption).foregroundStyle(.secondary)
            SearchableMenu(label: label, options: options) { id in
                coordinator.selectedRecipientID = id
            }
        }
    }

    private func display(_ r: RecipientsStore.Recipient) -> String {
        let name = r.username.isEmpty ? "(id \(r.userID))" : r.username
        let tags = r.sources.map { $0.rawValue.capitalized }.sorted().joined(separator: ", ")
        return tags.isEmpty ? name : "\(name) (\(tags))"
    }

    private func resourceRow(title: String,
                             resourceBinding: Binding<String>,
                             amountBinding: Binding<Int>) -> some View {
        let entries = resourcesStore.entries
        let selectedLabel = entries.first { $0.name == resourceBinding.wrappedValue }?.displayName
                            ?? resourceBinding.wrappedValue
        let options = entries.map {
            SearchableMenu<String>.Option(
                id: $0.name,
                title: $0.confirmed ? $0.displayName : "\($0.displayName) ?"
            )
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                SearchableMenu(label: selectedLabel, options: options) { name in
                    resourceBinding.wrappedValue = name
                }
                TextField("amount",
                          value: amountBinding,
                          format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
        }
    }

    private var sendRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { coordinator.send() }) {
                Text("Trade")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!coordinator.canSend)
            Button(action: { coordinator.sendReturn() }) {
                Text("Return Trade")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!coordinator.canSend)
            if !coordinator.lastSendStatus.isEmpty {
                Text(coordinator.lastSendStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
