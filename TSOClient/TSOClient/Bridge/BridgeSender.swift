import Observation
import WebKit

@Observable
final class BridgeSender {
    weak var webView: WKWebView?

    func send(_ command: OutboundCommand) {
        guard let webView else {
            print("[BridgeSender] webView is nil — message dropped")
            return
        }
        guard let js = renderJSExpression(for: command) else {
            print("[BridgeSender] failed to encode payload for \(command.type)")
            return
        }
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("[BridgeSender] JS error: \(error)")
            }
        }
    }
}
