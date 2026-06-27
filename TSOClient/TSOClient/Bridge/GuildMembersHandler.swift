import Foundation

struct GuildMembersHandler: InboundMessageHandler {
    let store: RecipientsStore
    let logger: Logger
    var type: String { "GUILD_MEMBERS" }
    func apply(payloadData: Data) throws {
        let payload = try JSONDecoder().decode(InboundMessage.PlayerRosterPayload.self, from: payloadData)
        store.applyGuildMembers(payload)
        logger.log("[TSO] Guild members received: \(payload.items.count)")
    }
}
