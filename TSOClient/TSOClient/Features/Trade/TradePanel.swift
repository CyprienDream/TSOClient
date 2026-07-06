import SwiftUI

struct TradePanel: View {
    var recipientsStore: RecipientsStore
    var resourcesStore: ResourcesStore
    var publicTradesStore: PublicTradesStore
    var coordinator: TradeCoordinator

    var body: some View {
        let recipients = recipientsStore.recipients
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if recipients.isEmpty {
                        placeholder
                    } else {
                        form(recipients: recipients)
                    }
                    Divider()
                    activeTradesSection
                }
            }
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
            lotsRow
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
            Button(action: { coordinator.sendPublic() }) {
                Text("Public trade")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!coordinator.canSendPublic)
            if !coordinator.lastSendStatus.isEmpty {
                Text(coordinator.lastSendStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeTradesSection: some View {
        let items = publicTradesStore.items
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("My public trades")
                    .font(.subheadline).bold()
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("None active. Waiting for the game to send a trade-window snapshot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { trade in
                    tradeRow(trade)
                }
            }
        }
        .padding(12)
    }

    private func tradeRow(_ trade: PublicTradesStore.PublicTrade) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(offerLabel(trade.offer))
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer()
                Button(role: .destructive, action: { coordinator.cancel(tradeId: trade.tradeId) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Cancel this trade (opcode 1056)")
            }
            HStack(spacing: 6) {
                Text("slot \(trade.slotType)/\(trade.slotPos)")
                if trade.lotsRemaining > 0 {
                    Text("×\(trade.lotsRemaining)")
                }
                if trade.remainingTime > 0 {
                    Text(remainingLabel(trade.remainingTime))
                }
                Spacer()
                Text("#\(trade.tradeId)").monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // Offer string is "<offerRes>|<costRes>|<lots>"; each side is
    // "<name>,<amount>" or "<verb>,<subject>,<amount>". Show it verbatim
    // for now — the panel is a debug/util view, we care about legibility
    // not localization.
    private func offerLabel(_ offer: String) -> String {
        let parts = offer.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return offer }
        return "\(parts[0]) → \(parts[1])"
    }

    private func remainingLabel(_ ms: Int) -> String {
        DurationFormatter.format(Double(ms) / 1_000)
    }

    // Ignored on Trade / Return Trade (those send lots=0). Stepper enforces
    // 1...4 so the coordinator can trust the value without re-clamping.
    private var lotsRow: some View {
        let binding = Binding(
            get: { coordinator.lots },
            set: { coordinator.lots = $0 })
        return VStack(alignment: .leading, spacing: 4) {
            Text("Lots").font(.caption).foregroundStyle(.secondary)
            Stepper(value: binding, in: 1...TradeCoordinator.maxLots) {
                Text("\(coordinator.lots)")
                    .monospacedDigit()
            }
            Text("Applies to public trade only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
