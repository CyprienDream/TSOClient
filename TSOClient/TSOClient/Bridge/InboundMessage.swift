import Foundation

// Namespace for the Decodable payload structs each inbound message handler
// understands. The runtime routing lives in `InboundDispatcher`; this file
// is data only.
enum InboundMessage {

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

    // Auto-detected player-wide buff status. Currently only PFB; expanded
    // as more zone-wide buffs (e.g. Premium Time) get wired up.
    struct PlayerBuffsPayload: Decodable {
        let pfbActive: Bool
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

    // Own active public trades from a type=1062 snapshot. Panels render one
    // row per item plus a delete button that fires opcode 1056 keyed by `id`.
    struct PublicTradesPayload: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let id: Int             // dTradeObjectVO.id — cancel opcode carries this
            let slotType: Int
            let slotPos: Int
            let type: Int           // 0/1/2/3 — trade kind (offer/buy/etc.); display-only
            let offer: String       // "<offerRes>|<costRes>|<lots>" pipe-encoded
            let remainingTime: Int  // ms until expiration
            let lotsRemaining: Int
        }
    }

    // Wire-confirmed resource names accumulated by the JS scanner. The
    // scanner only emits when the set grew, so a refresh on this message
    // is always a delta in the "got bigger" direction.
    struct ResourcesPayload: Decodable {
        let names: [String]
    }

    // Friend roster from dPlayerListVO (type=1014). Friends and guild
     // members share a normalized shape so the recipient picker can union
     // them by userID without two separate Decodable types downstream.
    struct PlayerRosterPayload: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let id: Int
            let username: String
            let level: Int
            let online: Bool
        }
    }

    struct SpecialistsPayload: Decodable {
        let items: [Item]
        let playerLevel: Int?

        struct Item: Decodable {
            let uid: String
            let uid1: Int
            let uid2: Int
            let specialistType: SpecialistKind
            let subTypeId: Int              // numeric specialistType from AMF (-1 if absent)
            let subTypeName: String?        // canonical name like "PirateExplorer" (nil if unmapped)
            let name: String
            let isIdle: Bool
            let skills: [SpecialistSkill]   // id + level, level>0 only
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
}
