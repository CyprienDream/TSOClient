import Observation
import WebKit

@Observable
final class BridgeSender {
    weak var webView: WKWebView?

    func send(_ msg: OutboundMessage) {
        webView.map(msg.send(to:))
    }
}
