import Foundation
import WebKit

// MARK: - JS → Swift (inbound)

enum InboundMessage {

    case collectibles(CollectiblesPayload)
    case gameState(GameStatePayload)
    case specialists(SpecialistsPayload)
    case calibrationDone(CalibrationPayload)

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

    struct CalibrationPayload {
        let tileHW: Double
        let tileHH: Double
        let originX: Double
        let originY: Double
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
        case "CALIBRATION_DONE": return decodeCalibration(payload)
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

    private static func decodeCalibration(_ raw: Any) -> InboundMessage? {
        guard let d = raw as? [String: Any],
              let hw = d["tileHW"] as? Double,
              let hh = d["tileHH"] as? Double,
              let ox = d["originX"] as? Double,
              let oy = d["originY"] as? Double else { return nil }
        return .calibrationDone(.init(tileHW: hw, tileHH: hh, originX: ox, originY: oy))
    }
}

// MARK: - Swift → JS (outbound)

enum OutboundMessage {
    case setOverlayEnabled(Bool)
    case setOverlayColor(hex: String)
    case render
    case calibrate(gx1: Double, gy1: Double, sx1: Double, sy1: Double,
                   gx2: Double, gy2: Double, sx2: Double, sy2: Double)
    case dispatchSpecialist(uid1: Int, uid2: Int, subTaskID: Int, targetGrid: Int)
    case rpcSend

    var jsExpression: String {
        switch self {
        case .setOverlayEnabled(let on):
            let v = on ? "true" : "false"
            return "window.TSOBridge?.receive({type:'SET_OVERLAY',payload:{enabled:\(v)}})"
        case .setOverlayColor(let hex):
            let safe = hex.replacingOccurrences(of: "'", with: "")
            return "window.TSOBridge?.receive({type:'SET_OVERLAY_COLOR',payload:{color:'\(safe)'}})"
        case .render:
            return "window.TSOBridge?.receive({type:'RENDER'})"
        case let .calibrate(gx1, gy1, sx1, sy1, gx2, gy2, sx2, sy2):
            return """
            window.TSOBridge?.receive({type:'CALIBRATE',payload:{
              gx1:\(gx1),gy1:\(gy1),sx1:\(sx1),sy1:\(sy1),
              gx2:\(gx2),gy2:\(gy2),sx2:\(sx2),sy2:\(sy2)
            }})
            """
        case let .dispatchSpecialist(uid1, uid2, subTaskID, targetGrid):
            return """
            window.TSOBridge?.receive({type:'DISPATCH_SPECIALIST',payload:{
              uid1:\(uid1),uid2:\(uid2),taskCode:\(subTaskID),targetGrid:\(targetGrid)
            }})
            """
        case .rpcSend:
            return ""
        }
    }

    func send(to webView: WKWebView) {
        webView.evaluateJavaScript(jsExpression, completionHandler: nil)
    }
}
