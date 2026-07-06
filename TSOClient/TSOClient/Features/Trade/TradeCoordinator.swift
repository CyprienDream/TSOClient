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

    // Trade-office bundle count for public trades (dTradeOfferVO.lots).
    // Ignored on private trades — those always send 0. The game caps this at
    // 4 (matches the trade-office UI); the panel enforces the range via a
    // 1...4 Stepper.
    var lots: Int = 1
    static let maxLots: Int = 4

    // Lightweight one-shot feedback for the panel: shown after a Trade
    // press, auto-cleared after `statusVisibleDuration` seconds so the
    // panel doesn't stay stuck on stale "Sent to …" copy after the next
    // trade is being composed.
    var lastSendStatus: String = ""

    private static let statusVisibleDuration: TimeInterval = 5
    private var statusClearTask: Task<Void, Never>?

    private let recipients: RecipientsStore
    private let publicTrades: PublicTradesStore
    private let dispatcher: TradeDispatchPort
    private let logger: Logger

    init(recipients: RecipientsStore,
         publicTrades: PublicTradesStore,
         dispatcher: TradeDispatchPort,
         logger: Logger = ConsoleLogger()) {
        self.recipients = recipients
        self.publicTrades = publicTrades
        self.dispatcher = dispatcher
        self.logger = logger
    }

    var canSend: Bool {
        selectedRecipientID > 0 &&
        !offerResource.isEmpty && offerAmount > 0 &&
        !costsResource.isEmpty && costsAmount > 0
    }

    // Public trade skips the recipient check — the wire uses receipientId=0
    // for trade-office listings (verified from a live dTradeObjectVO echo,
    // senderID=self, receiverID=0).
    var canSendPublic: Bool {
        !offerResource.isEmpty && offerAmount > 0 &&
        !costsResource.isEmpty && costsAmount > 0 &&
        lots >= 1 && lots <= Self.maxLots
    }

    func send() {
        guard canSend else {
            setStatus("Fill in all fields.")
            return
        }
        let name = recipientName()
        dispatchPair(name: name, returning: false)
        setStatus("Sent to \(name).")
    }

    // Fires the form trade, then a mirror trade with offer/cost swapped.
    // Use case: a "return" trade where the same partner can hand back what
    // they were sent — first call moves resources A→B, second pre-stages
    // the B→A return offer using the same form figures.
    func sendReturn() {
        guard canSend else {
            setStatus("Fill in all fields.")
            return
        }
        let name = recipientName()
        dispatchPair(name: name, returning: true)
        setStatus("Sent return pair to \(name).")
    }

    // Places the offer in the trade office (receipientId=0). `slotType`
    // is determined by the shape of the ask, verified from the game's own
    // outbound 2026-07-06:
    //   • costsRes populated (resource ask)      → slotType=2
    //   • costsBuff populated (building/buff ask) → slotType=0
    // The panel currently only builds resource-for-resource trades, so we
    // always send 2. slotPos is auto-picked by the encoder from
    // _tsoOwnPublicTradeSlots. The server auto-deducts the coin fee for
    // slotPos > 0 based on the player's total active-trade count — no
    // coin field on the wire.
    func sendPublic() {
        guard canSendPublic else {
            setStatus("Fill in all fields.")
            return
        }
        logger.log("[Trade] public offer — " +
                   "\(offerAmount)×\(offerResource) for \(costsAmount)×\(costsResource) ×\(lots)")
        dispatcher.dispatchTrade(
            receipientId: 0,
            offerResource: offerResource, offerAmount: offerAmount,
            costsResource: costsResource, costsAmount: costsAmount,
            lots: lots,
            slotType: 2 // resource-for-resource ask category
        )
        setStatus("Placed public offer (×\(lots)).")
    }

    // Cancel one of our own public trades. The store optimistically drops
    // the row so the panel updates instantly; the next 1062 snapshot
    // reconfirms or restores the row if the server refused.
    func cancel(tradeId: Int) {
        logger.log("[Trade] cancel id=\(tradeId)")
        publicTrades.remove(tradeId: tradeId)
        dispatcher.cancelTrade(tradeId: tradeId)
        setStatus("Cancelled trade #\(tradeId).")
    }

    private func dispatchPair(name: String, returning: Bool) {
        logger.log("[Trade] send to \(name) — " +
                   "\(offerAmount)×\(offerResource) for \(costsAmount)×\(costsResource)")
        dispatcher.dispatchTrade(
            receipientId: selectedRecipientID,
            offerResource: offerResource, offerAmount: offerAmount,
            costsResource: costsResource, costsAmount: costsAmount,
            lots: 0, // private trade — game observed lots=0
            slotType: 4
        )
        guard returning else { return }
        logger.log("[Trade] return to \(name) — " +
                   "\(costsAmount)×\(costsResource) for \(offerAmount)×\(offerResource)")
        dispatcher.dispatchTrade(
            receipientId: selectedRecipientID,
            offerResource: costsResource, offerAmount: costsAmount,
            costsResource: offerResource, costsAmount: offerAmount,
            lots: 0,
            slotType: 4
        )
    }

    private func recipientName() -> String {
        recipients.recipient(id: selectedRecipientID)?.username
            ?? "(id \(selectedRecipientID))"
    }

    private func setStatus(_ message: String) {
        lastSendStatus = message
        statusClearTask?.cancel()
        guard !message.isEmpty else { return }
        let delay = Self.statusVisibleDuration
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.lastSendStatus = ""
        }
    }
}
