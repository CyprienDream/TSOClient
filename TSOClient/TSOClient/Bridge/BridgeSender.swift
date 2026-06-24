import Observation
import WebKit

@Observable
final class BridgeSender: OutboundDispatching {
    weak var webView: WKWebView?
    private let logger: Logger

    init(logger: Logger = ConsoleLogger()) {
        self.logger = logger
    }

    func send(_ command: WireCommand) {
        guard let webView else {
            logger.log("[BridgeSender] webView is nil — message dropped")
            return
        }
        guard let js = renderJSExpression(for: command) else {
            logger.log("[BridgeSender] failed to encode payload for \(command.type)")
            return
        }
        webView.evaluateJavaScript(js) { [logger] _, error in
            if let error {
                logger.log("[BridgeSender] JS error: \(error)")
            }
        }
    }

    // Drops cached resources from the active data store and triggers a reload.
    // Long sessions accumulate Unity asset blobs, AMF response copies retained
    // by WebKit's intermediate caches, and SwiftUI binding state; a manual
    // reload is the cheapest recovery short of restarting the app.
    func reloadWebView() {
        guard let webView else {
            logger.log("[BridgeSender] reload requested but webView is nil")
            return
        }
        let store = webView.configuration.websiteDataStore
        let types: Set<String> = [
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        let since = Date(timeIntervalSince1970: 0)
        store.removeData(ofTypes: types, modifiedSince: since) { [weak webView, logger] in
            logger.log("[BridgeSender] cache purged, reloading webview")
            webView?.reload()
        }
    }
}
