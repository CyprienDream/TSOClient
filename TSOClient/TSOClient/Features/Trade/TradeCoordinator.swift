import Foundation
import Observation

// View-model for the TradePanel. Holds the user's current selection and
// the send action. Recipient is identified by userID; the display
// username comes from RecipientsStore so the bank player's name (LOPC
// in the seed account) shows up correctly without being hardcoded.
@Observable
final class TradeCoordinator {
    // Default = the seed bank player's userID (LOPC, observed 2026-06-27).
    // Stays selected on launch even before the friends/guild payloads
    // arrive; the panel resolves it to a username via RecipientsStore.
    static let defaultRecipientID: Int = 1928723

    var selectedRecipientID: Int = TradeCoordinator.defaultRecipientID

    // Default resource picks: offer Tools (typical bank deposit), ask Wood
    // (single-unit ask so the recipient won't accept — offer expires and
    // the offered resources land in the sender's star menu).
    var offerResource: String = "Tool"
    var offerAmount: Int = 100_000
    var costsResource: String = "Wood"
    var costsAmount: Int = 1

    // Lightweight one-shot feedback for the panel: shown after a Trade
    // press, cleared on next interaction.
    var lastSendStatus: String = ""

    private let recipients: RecipientsStore
    private let dispatcher: TradeDispatchPort
    private let logger: Logger

    init(recipients: RecipientsStore,
         dispatcher: TradeDispatchPort,
         logger: Logger = ConsoleLogger()) {
        self.recipients = recipients
        self.dispatcher = dispatcher
        self.logger = logger
    }

    var canSend: Bool {
        selectedRecipientID > 0 &&
        !offerResource.isEmpty && offerAmount > 0 &&
        !costsResource.isEmpty && costsAmount > 0
    }

    func send() {
        guard canSend else {
            lastSendStatus = "Fill in all fields."
            return
        }
        let name = recipientName()
        dispatchPair(name: name, returning: false)
        lastSendStatus = "Sent to \(name)."
    }

    // Fires the form trade, then a mirror trade with offer/cost swapped.
    // Use case: a "return" trade where the same partner can hand back what
    // they were sent — first call moves resources A→B, second pre-stages
    // the B→A return offer using the same form figures.
    func sendReturn() {
        guard canSend else {
            lastSendStatus = "Fill in all fields."
            return
        }
        let name = recipientName()
        dispatchPair(name: name, returning: true)
        lastSendStatus = "Sent return pair to \(name)."
    }

    private func dispatchPair(name: String, returning: Bool) {
        logger.log("[Trade] send to \(name) — " +
                   "\(offerAmount)×\(offerResource) for \(costsAmount)×\(costsResource)")
        dispatcher.dispatchTrade(
            receipientId: selectedRecipientID,
            offerResource: offerResource, offerAmount: offerAmount,
            costsResource: costsResource, costsAmount: costsAmount,
            slotType: 4 // private trade
        )
        guard returning else { return }
        logger.log("[Trade] return to \(name) — " +
                   "\(costsAmount)×\(costsResource) for \(offerAmount)×\(offerResource)")
        dispatcher.dispatchTrade(
            receipientId: selectedRecipientID,
            offerResource: costsResource, offerAmount: costsAmount,
            costsResource: offerResource, costsAmount: offerAmount,
            slotType: 4
        )
    }

    private func recipientName() -> String {
        recipients.recipient(id: selectedRecipientID)?.username
            ?? "(id \(selectedRecipientID))"
    }
}
