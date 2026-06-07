import Foundation

enum InboundMessage {

    case collectibles(CollectiblesPayload)
    case gameState(GameStatePayload)
    case specialists(SpecialistsPayload)
    case buildings(BuildingsPayload)
    case buffs(BuffsPayload)

    struct CollectiblesPayload: Decodable {
        let mapWidth: Int
        let mapHeight: Int
        let items: [Item]

        struct Item: Decodable {
            let gridIndex: Int
            let x: Int
            let y: Int
            let assetName: String
        }
    }

    struct GameStatePayload: Decodable {
        let state: String   // "LOADED" | "ZONE_CHANGED" | "ZONE_LEFT"
        let zoneId: Int?
    }

    struct BuildingsPayload: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let gridIndex: Int
            let skin: String        // building type name, e.g. "Woodcutter_01"
            let uid1: Int
            let uid2: Int
            let activeBuff: String? // buffName_string of the first active buff, if any
        }
    }

    struct BuffsPayload: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let uid1: Int
            let uid2: Int
            let buffName: String        // e.g. "HiredMilitary"
            let resourceName: String    // e.g. "Recruit" (empty for non-resource buffs)
            let amount: Int             // quantity in inventory
            let insertedAt: Int         // Unix timestamp
        }
    }

    struct SpecialistsPayload: Decodable {
        let items: [Item]
        let playerLevel: Int?
        let serverTime: Double?

        struct Item: Decodable {
            let uid: String
            let uid1: Int
            let uid2: Int
            let specialistType: SpecialistKind
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

            // JS emits the legacy capital-D "taskSubTaskID" key.
            enum CodingKeys: String, CodingKey {
                case uid, uid1, uid2, specialistType, subTypeId, subTypeName
                case name, isIdle, skills, collectedTime, bonusTime, taskEndTime
                case taskActionType
                case taskSubTaskId = "taskSubTaskID"
            }
        }
    }

    static func decode(name: String, body: Any) -> InboundMessage? {
        guard name == "tso",
              let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              let payload = dict["payload"],
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }

        let decoder = JSONDecoder()
        do {
            switch type {
            case "COLLECTIBLES": return .collectibles(try decoder.decode(CollectiblesPayload.self, from: data))
            case "GAME_STATE":   return .gameState(try decoder.decode(GameStatePayload.self, from: data))
            case "SPECIALISTS":  return .specialists(try decoder.decode(SpecialistsPayload.self, from: data))
            case "BUILDINGS":    return .buildings(try decoder.decode(BuildingsPayload.self, from: data))
            case "BUFFS":        return .buffs(try decoder.decode(BuffsPayload.self, from: data))
            default:             return nil
            }
        } catch {
            print("[InboundMessage] decode error for '\(type)': \(error)")
            return nil
        }
    }
}
