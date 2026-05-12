import WebKit

// Loads the four active JS modules from Resources/JS/ in the required injection
// order: bridge → scanner → encoder → patcher.
enum JSInjection {

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
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing JS resource: \(name).js")
        }
        return src
    }

    private static func resolvePatched(_ name: String) -> String {
        var src = load(name)
        guard let hashURL = Bundle.main.url(forResource: "collectible-hashes", withExtension: "json"),
              let hashData = try? Data(contentsOf: hashURL),
              let hashJSON = String(data: hashData, encoding: .utf8) else {
            fatalError("Missing Data resource: collectible-hashes.json")
        }
        src = src.replacingOccurrences(of: "/*__HASHES__*/[]", with: hashJSON)
        return src
    }
}
