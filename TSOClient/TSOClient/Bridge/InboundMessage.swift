import Foundation

enum InboundMessage {

    case collectibles(CollectiblesPayload)
    case gameState(GameStatePayload)
    case specialists(SpecialistsPayload)

    struct CollectiblesPayload {
        let mapWidth: Int
        let mapHeight: Int
        let items: [Item]

        struct Item {
            let gridIndex: Int
            let x: Int
            let y: Int
            let assetName: String
        }
    }

    struct GameStatePayload {
        let state: String   // "LOADED" | "ZONE_CHANGED" | "ZONE_LEFT"
        let zoneId: Int?
    }

    struct SpecialistsPayload {
        let items: [Item]
        let playerLevel: Int?
        let serverTime: Double?

        struct Item {
            let uid: String
            let uid1: Int
            let uid2: Int
            let specialistType: String      // "Explorer" | "Geologist" | "General" | "Unknown"
            let subTypeId: Int              // numeric specialistType from AMF (-1 if absent)
            let subTypeName: String?        // canonical name like "PirateExplorer" (nil if unmapped)
            let name: String
            let isIdle: Bool
            let skills: [Int]               // skill IDs with level > 0
            let collectedTime: Int?         // game-clock value at task start (unit TBD)
            let bonusTime: Int?
            let taskEndTime: Double?
        }
    }

    static func decode(name: String, body: Any) -> InboundMessage? {
        guard name == "tso",
              let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              let payload = dict["payload"] else { return nil }

        switch type {
        case "COLLECTIBLES":    return decodeCollectibles(payload)
        case "GAME_STATE":      return decodeGameState(payload)
        case "SPECIALISTS":     return decodeSpecialists(payload)
        default:                return nil
        }
    }

    private static func decodeCollectibles(_ raw: Any) -> InboundMessage? {
        guard let d = raw as? [String: Any],
              let mw = d["mapWidth"] as? Int,
              let mh = d["mapHeight"] as? Int,
              let rawItems = d["items"] as? [[String: Any]] else { return nil }

        let items: [CollectiblesPayload.Item] = rawItems.compactMap { item in
            guard let gi = item["gridIndex"] as? Int,
                  let x  = item["x"] as? Int,
                  let y  = item["y"] as? Int else { return nil }
            let name = item["assetName"] as? String ?? ""
            return .init(gridIndex: gi, x: x, y: y, assetName: name)
        }
        return .collectibles(.init(mapWidth: mw, mapHeight: mh, items: items))
    }

    private static func decodeGameState(_ raw: Any) -> InboundMessage? {
        guard let d = raw as? [String: Any],
              let state = d["state"] as? String else { return nil }
        return .gameState(.init(state: state, zoneId: d["zoneId"] as? Int))
    }

    private static func decodeSpecialists(_ raw: Any) -> InboundMessage? {
        guard let d = raw as? [String: Any],
              let rawItems = d["items"] as? [[String: Any]] else { return nil }

        let items: [SpecialistsPayload.Item] = rawItems.compactMap { s in
            guard let uid  = s["uid"]  as? String,
                  let uid1 = s["uid1"] as? Int,
                  let uid2 = s["uid2"] as? Int else { return nil }
            let skillsArr = (s["skills"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            return .init(
                uid:            uid,
                uid1:           uid1,
                uid2:           uid2,
                specialistType: s["specialistType"] as? String ?? "Unknown",
                subTypeId:      s["subTypeId"]      as? Int    ?? -1,
                subTypeName:    s["subTypeName"]    as? String,
                name:           s["name"]           as? String ?? "",
                isIdle:         s["isIdle"]         as? Bool   ?? true,
                skills:         skillsArr,
                collectedTime:  s["collectedTime"]  as? Int,
                bonusTime:      s["bonusTime"]      as? Int,
                taskEndTime:    s["taskEndTime"]    as? Double
            )
        }
        return .specialists(.init(
            items:       items,
            playerLevel: d["playerLevel"] as? Int,
            serverTime:  d["serverTime"]  as? Double
        ))
    }
}
