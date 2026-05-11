import SwiftUI
import WebKit

// MARK: - WebView (NSViewRepresentable)

struct WebView: NSViewRepresentable {
    let url: URL
    var store: CollectiblesStore
    var specialistsStore: SpecialistsStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = config.userContentController

        JSLoader.install(into: controller)

        // "logger" → raw debug strings; "tso" → structured JSON payloads
        controller.add(context.coordinator, name: "logger")
        controller.add(context.coordinator, name: "tso")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate       = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent  =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        webView.isInspectable = true
        context.coordinator.webView = webView
        context.coordinator.registerNotifications()
        NotificationCenter.default.post(name: .tsoWebViewReady, object: webView)
        return webView
    }

    // Only load once — guard prevents reloading on every SwiftUI update.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, specialistsStore: specialistsStore)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

        var store: CollectiblesStore
        var specialistsStore: SpecialistsStore
        weak var webView: WKWebView?

        init(store: CollectiblesStore, specialistsStore: SpecialistsStore) {
            self.store = store
            self.specialistsStore = specialistsStore
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

        // MARK: Bridge dispatch

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
                guard let self else { return }
                switch msg {
                case .collectibles(let payload):
                    self.store.apply(payload)
                    print("[TSO] Collectibles received: \(payload.items.count) items on \(payload.mapWidth)×\(payload.mapHeight) map")
                case .gameState(let payload):
                    print("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
                    if payload.state == "ZONE_LEFT" {
                        self.store.clear()
                        self.specialistsStore.clear()
                    }
                case .specialists(let payload):
                    self.specialistsStore.apply(payload)
                    print("[TSO] Specialists received: \(payload.items.count)")
                }
            }
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @State private var store = CollectiblesStore()
    @State private var specialistsStore = SpecialistsStore()

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!,
                    store: store,
                    specialistsStore: specialistsStore)
                .frame(minWidth: 800, minHeight: 768)

            SpecialistsPanel(store: specialistsStore) { uid1, uid2, subTaskID, targetGrid in
                let js = """
                window._TSORPC?.dispatchSpecialist({
                    uid1:\(uid1),uid2:\(uid2),
                    taskCode:\(subTaskID),targetGrid:\(targetGrid)
                })
                """
                NotificationCenter.default.post(
                    name: .tsoEvaluateJS, object: nil,
                    userInfo: ["js": js])
            }
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}

extension Notification.Name {
    static let tsoEvaluateJS  = Notification.Name("tsoEvaluateJS")
    static let tsoWebViewReady = Notification.Name("tsoWebViewReady")
}

// MARK: - JS module loader
// Loads the four active JS modules from Resources/JS/ in the required injection
// order: bridge → scanner → encoder → patcher.

private enum JSLoader {

    // Injection order: bridge → scanner → encoder → patcher.
    // The patcher must run after the scanner because it wraps the scanner's
    // already-patched window.fetch. DO NOT reorder.
    static func install(into controller: WKUserContentController) {
        let sources = [
            load("bridge"),
            load("amf3-scanner"),
            load("amf3-encoder"),
            resolvePatched("collectible-patcher"),
        ]
        for source in sources {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
    }

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "JS"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing JS resource: \(name).js")
        }
        return src
    }

    private static func resolvePatched(_ name: String) -> String {
        var src = load(name)
        guard let hashURL = Bundle.main.url(forResource: "collectible-hashes", withExtension: "json", subdirectory: "Data"),
              let hashData = try? Data(contentsOf: hashURL),
              let hashJSON = String(data: hashData, encoding: .utf8) else {
            fatalError("Missing Data resource: collectible-hashes.json")
        }
        src = src.replacingOccurrences(of: "/*__HASHES__*/[]", with: hashJSON)
        return src
    }
}
