import Foundation
import WebKit

// MARK: - JS → Swift (inbound)

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

        struct Item {
            let uid: String
            let uid1: Int
            let uid2: Int
            let specialistType: String
            let name: String
            let level: Int
            let isIdle: Bool
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
            return .init(
                uid:            uid,
                uid1:           uid1,
                uid2:           uid2,
                specialistType: s["specialistType"] as? String ?? "Unknown",
                name:           s["name"]           as? String ?? "",
                level:          s["level"]          as? Int    ?? 1,
                isIdle:         s["isIdle"]         as? Bool   ?? true,
                taskEndTime:    s["taskEndTime"]     as? Double
            )
        }
        return .specialists(.init(items: items))
    }

}

// MARK: - Swift → JS (outbound)

enum OutboundMessage {
    case dispatchSpecialist(uid1: Int, uid2: Int, subTaskID: Int, targetGrid: Int)

    var jsExpression: String {
        switch self {
        case let .dispatchSpecialist(uid1, uid2, subTaskID, targetGrid):
            return """
            window.TSOBridge?.receive({type:'DISPATCH_SPECIALIST',payload:{
              uid1:\(uid1),uid2:\(uid2),taskCode:\(subTaskID),targetGrid:\(targetGrid)
            }})
            """
        }
    }

    func send(to webView: WKWebView) {
        webView.evaluateJavaScript(jsExpression, completionHandler: nil)
    }
}
