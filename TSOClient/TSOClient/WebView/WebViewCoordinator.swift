import WebKit

final class WebViewCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private let inbound: InboundDispatcher
    private let logger: Logger
    weak var webView: WKWebView?

    init(inbound: InboundDispatcher, logger: Logger) {
        self.inbound = inbound
        self.logger = logger
    }

    // Open target="_blank" links inside the same view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // Block in-game buttons that navigate the main frame away from the game
    // (e.g. the rankings button next to the star menu hits /redirect/rankings).
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.path.hasPrefix("/redirect/") {
            logger.log("[TSO] Blocked navigation away from game: \(url.absoluteString)")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation _: WKNavigation!,
                 withError error: Error) {
        logger.log("[TSO] Navigation error: \(error.localizedDescription)")
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "logger" {
            logger.log("[JS] \(message.body)")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.inbound.dispatch(name: message.name, body: message.body)
        }
    }
}
