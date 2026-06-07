import WebKit

enum OutboundMessage {
    case dispatchSpecialist(uid1: Int, uid2: Int, actionType: Int, subTaskID: Int, targetGrid: Int)
    case dispatchBuff(buffUid1: Int, buffUid2: Int, targetGrid: Int)

    var jsExpression: String {
        switch self {
        case let .dispatchSpecialist(uid1, uid2, actionType, subTaskID, targetGrid):
            return """
            (function(){
              try { webkit.messageHandlers.logger.postMessage('[Swift→JS] DISPATCH uid=\(uid1):\(uid2) at=\(actionType) st=\(subTaskID) g=\(targetGrid)'); } catch(_) {}
              if (window.TSOBridge) { window.TSOBridge.receive({type:'DISPATCH_SPECIALIST',payload:{uid1:\(uid1),uid2:\(uid2),actionType:\(actionType),taskCode:\(subTaskID),targetGrid:\(targetGrid)}}); }
              else { try { webkit.messageHandlers.logger.postMessage('[Swift→JS] TSOBridge not ready'); } catch(_) {} }
            })()
            """
        case let .dispatchBuff(buffUid1, buffUid2, targetGrid):
            return """
            (function(){
              try { webkit.messageHandlers.logger.postMessage('[Swift→JS] DISPATCH_BUFF uid=\(buffUid1):\(buffUid2) g=\(targetGrid)'); } catch(_) {}
              if (window.TSOBridge) { window.TSOBridge.receive({type:'DISPATCH_BUFF',payload:{buffUid1:\(buffUid1),buffUid2:\(buffUid2),targetGrid:\(targetGrid)}}); }
              else { try { webkit.messageHandlers.logger.postMessage('[Swift→JS] TSOBridge not ready'); } catch(_) {} }
            })()
            """
        }
    }

    func send(to webView: WKWebView) {
        webView.evaluateJavaScript(jsExpression) { _, error in
            if let error {
                print("[BridgeSender] JS error: \(error)")
            }
        }
    }
}
