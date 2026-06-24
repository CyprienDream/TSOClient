import WebKit

// Loads the active JS modules from Resources/JS/ in the required injection
// order: bridge → parser → classifier → scanner → net → encoder → patcher → unity-probe.
enum JSInjection {

    // Injection order matters:
    //   bridge      — sets up window.TSOBridge + window._tsoSend
    //   amf3-parser — defines window._TSOAMFParser
    //   amf3-classifier — defines window._tsoClassifier (subtype tables + learn)
    //   amf3-scanner — defines window._tsoScanner.analyzeAMFBuffer
    //   amf3-net    — wraps window.fetch + XMLHttpRequest, calls scanner
    //   amf3-encoder — defines window._TSORPC (uses _TSOAMFParser, _tsoAuthCtx)
    //   collectible-patcher — wraps window.fetch AGAIN (must run after amf3-net
    //     so it wraps the already-wrapped fetch; otherwise AMF3 parsing on
    //     non-collectible URLs breaks). DO NOT reorder.
    //   unity-probe — touches window.createUnityInstance only; ordering relative
    //     to the fetch chain doesn't matter.
    static func modules() -> [JSModule] {
        [
            JSModule("bridge"),
            JSModule("amf3-parser"),
            JSModule("amf3-classifier"),
            JSModule("amf3-scanner"),
            JSModule("amf3-net"),
            JSModule("amf3-encoder"),
            JSModule("collectible-patcher", preProcess: { src in
                guard let hashURL = Bundle.main.url(forResource: "collectible-hashes", withExtension: "json"),
                      let hashData = try? Data(contentsOf: hashURL),
                      let hashJSON = String(data: hashData, encoding: .utf8) else {
                    fatalError("Missing Data resource: collectible-hashes.json")
                }
                return src.replacingOccurrences(of: "/*__HASHES__*/[]", with: hashJSON)
            }),
            JSModule("unity-probe"),
        ]
    }

    static func install(into controller: WKUserContentController) {
        for module in modules() {
            var src = load(module.name)
            if let preProcess = module.preProcess { src = preProcess(src) }
            controller.addUserScript(
                WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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
}
