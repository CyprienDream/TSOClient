import Foundation
import Observation

// Recipients = friends ∪ guild members, deduped by userID. The trade
// recipient picker reads from this single store so the dropdown contains
// every player we could conceivably address, regardless of which list
// they appeared in.
@Observable
final class RecipientsStore {
    struct Recipient: Identifiable, Hashable {
        var id: Int { userID }
        let userID: Int
        let username: String
        let level: Int
        let online: Bool
        let sources: Set<Source>
    }
    enum Source: String, Hashable { case friend, guild }

    private var friends: [Int: InboundMessage.PlayerRosterPayload.Item] = [:]
    private var guildMembers: [Int: InboundMessage.PlayerRosterPayload.Item] = [:]

    // Sorted by username, case-insensitive. Empty-username entries sink to
    // the bottom so the picker stays scannable even when the wire layout
    // changes and a field comes through blank.
    private(set) var recipients: [Recipient] = []

    func applyFriends(_ payload: InboundMessage.PlayerRosterPayload) {
        friends = Dictionary(uniqueKeysWithValues: payload.items.map { ($0.id, $0) })
        rebuild()
    }

    func applyGuildMembers(_ payload: InboundMessage.PlayerRosterPayload) {
        guildMembers = Dictionary(uniqueKeysWithValues: payload.items.map { ($0.id, $0) })
        rebuild()
    }

    func recipient(id: Int) -> Recipient? {
        recipients.first { $0.userID == id }
    }

    private func rebuild() {
        var byID: [Int: Recipient] = [:]
        for (id, f) in friends {
            byID[id] = Recipient(userID: id, username: f.username, level: f.level,
                                 online: f.online, sources: [.friend])
        }
        for (id, g) in guildMembers {
            if let existing = byID[id] {
                var srcs = existing.sources
                srcs.insert(.guild)
                byID[id] = Recipient(
                    userID: id,
                    // Prefer the non-empty username; both lists usually agree.
                    username: existing.username.isEmpty ? g.username : existing.username,
                    level: max(existing.level, g.level),
                    online: existing.online || g.online,
                    sources: srcs
                )
            } else {
                byID[id] = Recipient(userID: id, username: g.username, level: g.level,
                                     online: g.online, sources: [.guild])
            }
        }
        recipients = byID.values.sorted {
            if $0.username.isEmpty != $1.username.isEmpty { return !$0.username.isEmpty }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }
}
