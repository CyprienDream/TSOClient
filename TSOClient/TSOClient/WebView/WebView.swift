import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL
    var store: CollectiblesStore
    var specialistsStore: SpecialistsStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = config.userContentController

        JSInjection.install(into: controller)

        // "logger" → raw debug strings; "tso" → structured JSON payloads
        controller.add(context.coordinator, name: "logger")
        controller.add(context.coordinator, name: "tso")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate         = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent    =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        webView.isInspectable = true
        context.coordinator.webView = webView
        context.coordinator.registerNotifications()
        NotificationCenter.default.post(name: .tsoWebViewReady, object: webView)
        return webView
    }

    // INVARIANT: do not remove — guard prevents game reload on every SwiftUI state change.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(store: store, specialistsStore: specialistsStore)
    }
}
