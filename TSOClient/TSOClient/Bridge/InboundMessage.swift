import Foundation

enum InboundMessage {

    case collectibles(CollectiblesPayload)
    case gameState(GameStatePayload)
    case specialists(SpecialistsPayload)
    case buildings(BuildingsPayload)
    case buffs(BuffsPayload)

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

    struct BuildingsPayload {
        let items: [Item]

        struct Item {
            let gridIndex: Int
            let skin: String        // building type name, e.g. "Woodcutter_01"
            let uid1: Int
            let uid2: Int
            let activeBuff: String? // buffName_string of the first active buff, if any
        }
    }

    struct BuffsPayload {
        let items: [Item]

        struct Item {
            let uid1: Int
            let uid2: Int
            let buffName: String        // e.g. "HiredMilitary"
            let resourceName: String    // e.g. "Recruit" (empty for non-resource buffs)
            let amount: Int             // quantity in inventory
            let insertedAt: Int         // Unix timestamp
        }
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
            let collectedTime: Int?         // elapsed ms since task start (counts up)
            let bonusTime: Int?
            let taskEndTime: Double?
            let taskActionType: Int?        // dServerAction.type while busy (0=Geo,1/2=Exp,12=Gen)
            let taskSubTaskId: Int?         // dStartSpecialistTaskVO.subTaskID while busy
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
        case "BUILDINGS":       return decodeBuildings(payload)
        case "BUFFS":           return decodeBuffs(payload)
        default:                return nil
        }
    }

    private static func decodeBuildings(_ raw: Any) -> InboundMessage? {
        guard let d = raw as? [String: Any],
              let rawItems = d["items"] as? [[String: Any]] else { return nil }
        let items: [BuildingsPayload.Item] = rawItems.compactMap { b in
            guard let gi = b["gridIndex"] as? Int else { return nil }
            return .init(
                gridIndex:  gi,
                skin:       b["skin"]        as? String ?? "",
                uid1:       b["uid1"]        as? Int    ?? 0,
                uid2:       b["uid2"]        as? Int    ?? 0,
                activeBuff: b["activeBuff"]  as? String
            )
        }
        return .buildings(.init(items: items))
    }

    private static func decodeBuffs(_ raw: Any) -> InboundMessage? {
        guard let d = raw as? [String: Any],
              let rawItems = d["items"] as? [[String: Any]] else { return nil }
        let items: [BuffsPayload.Item] = rawItems.compactMap { b in
            return .init(
                uid1:         b["uid1"]         as? Int    ?? 0,
                uid2:         b["uid2"]         as? Int    ?? 0,
                buffName:     b["buffName"]      as? String ?? "",
                resourceName: b["resourceName"]  as? String ?? "",
                amount:       b["amount"]        as? Int    ?? 0,
                insertedAt:   b["insertedAt"]    as? Int    ?? 0
            )
        }
        return .buffs(.init(items: items))
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
                collectedTime:  s["collectedTime"]   as? Int,
                bonusTime:      s["bonusTime"]       as? Int,
                taskEndTime:    s["taskEndTime"]     as? Double,
                taskActionType: s["taskActionType"]  as? Int,
                taskSubTaskId:  s["taskSubTaskID"]   as? Int
            )
        }
        return .specialists(.init(
            items:       items,
            playerLevel: d["playerLevel"] as? Int,
            serverTime:  d["serverTime"]  as? Double
        ))
    }
}
