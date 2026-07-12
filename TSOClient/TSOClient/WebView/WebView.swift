import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL
    // Narrow injection: WebView only needs to (a) hand the WKWebView to the
    // JS executor (late binding) and (b) construct a coordinator that
    // routes inbound messages. The executor owns the WKWebView reference
    // so BridgeSender stays decoupled from WebKit.
    let executor: WKWebViewJSExecutor
    let inbound: InboundDispatcher
    let logger: Logger

    // Purges the WebKit network process's in-memory + fetch caches every
    // 5 min. WKWebView's cache is otherwise unbounded across a session and
    // grows steadily as the Unity build streams texture bundles.
    private static var cachePurgeTimer: Timer?

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

        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.webView = webView
        executor.webView = webView  // Assign before any UI can trigger a dispatch.

        if Self.cachePurgeTimer == nil {
            let store = config.websiteDataStore
            let types: Set<String> = [
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache,
            ]
            Self.cachePurgeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                store.removeData(ofTypes: types, modifiedSince: .distantPast) { }
            }
        }
        return webView
    }

    // INVARIANT: do not remove — guard prevents game reload on every SwiftUI state change.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(inbound: inbound, logger: logger)
    }
}
