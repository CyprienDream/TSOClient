import Observation
import WebKit

@Observable
final class BridgeSender {
    weak var webView: WKWebView?

    func send(_ msg: OutboundMessage) {
        guard let webView else {
            print("[BridgeSender] webView is nil — message dropped")
            return
        }
        msg.send(to: webView)
    }
}
