import Foundation
import WebKit

// Evaluates JS expressions. BridgeSender depends on this protocol instead
// of holding a WKWebView directly, so the wire format (serializer) and
// the transport (this) are independently substitutable.
protocol JSExecutor: AnyObject {
    func evaluate(_ js: String)
}

// Production conformer. The WKWebView is assigned late (in
// WebView.makeNSView) so the executor exists before the view does;
// missing-webView dispatches log and silently drop, matching prior behaviour.
final class WKWebViewJSExecutor: JSExecutor {
    weak var webView: WKWebView?
    private let logger: Logger

    init(logger: Logger = ConsoleLogger()) {
        self.logger = logger
    }

    func evaluate(_ js: String) {
        guard let webView else {
            logger.log("[BridgeSender] webView is nil — message dropped")
            return
        }
        webView.evaluateJavaScript(js) { [logger] _, error in
            if let error {
                logger.log("[BridgeSender] JS error: \(error)")
            }
        }
    }

    // Tears down the current page's JS heap + GL context. Used by the
    // "Reload" button to reclaim Unity's texture pool + wasm heap when
    // long play sessions accumulate memory.
    func reloadGame() {
        guard let webView else {
            logger.log("[Reload] webView is nil — reload skipped")
            return
        }
        logger.log("[Reload] reloading WKWebView to reset RAM")
        webView.reload()
    }
}
