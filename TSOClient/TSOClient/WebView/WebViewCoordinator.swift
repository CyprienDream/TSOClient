import WebKit

final class WebViewCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private let inbound: InboundDispatcher
    private let logger: Logger
    weak var webView: WKWebView?

    init(env: AppEnvironment) {
        self.inbound = env.inbound
        self.logger = env.logger
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
