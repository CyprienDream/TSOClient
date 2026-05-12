import WebKit

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
