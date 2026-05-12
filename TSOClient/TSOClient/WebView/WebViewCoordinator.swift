import WebKit

final class WebViewCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private let router: BridgeRouter
    weak var webView: WKWebView?

    init(store: CollectiblesStore, specialistsStore: SpecialistsStore) {
        self.router = BridgeRouter(collectibles: store, specialists: specialistsStore)
    }

    func registerNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEvaluateJS(_:)),
            name: .tsoEvaluateJS, object: nil)
    }

    @objc private func handleEvaluateJS(_ note: Notification) {
        guard let js = note.userInfo?["js"] as? String else { return }
        webView?.evaluateJavaScript(js, completionHandler: nil)
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
        print("[TSO] Navigation error: \(error.localizedDescription)")
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "logger" {
            print("[JS] \(message.body)")
            return
        }

        guard let msg = InboundMessage.decode(name: message.name, body: message.body) else {
            print("[TSO] Unknown message from '\(message.name)': \(message.body)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.router.route(msg)
        }
    }
}
