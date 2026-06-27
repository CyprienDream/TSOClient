import Foundation

struct FriendsHandler: InboundMessageHandler {
    let store: RecipientsStore
    let logger: Logger
    var type: String { "FRIENDS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.PlayerRosterPayload.self, from: payloadData)
        store.applyFriends(payload)
        logger.log("[TSO] Friends received: \(payload.items.count)")
    }
}
