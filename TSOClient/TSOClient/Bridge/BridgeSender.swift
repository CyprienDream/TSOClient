import Observation
import WebKit

@Observable
final class BridgeSender: OutboundDispatching {
    weak var webView: WKWebView?
    private let logger: Logger
    private let serializer: WireCommandJSSerializing

    init(logger: Logger = ConsoleLogger(),
         serializer: WireCommandJSSerializing = DefaultWireCommandJSSerializer()) {
        self.logger = logger
        self.serializer = serializer
    }

    func send(_ command: WireCommand) {
        guard let webView else {
            logger.log("[BridgeSender] webView is nil — message dropped")
            return
        }
        guard let js = serializer.serialize(command) else {
            logger.log("[BridgeSender] failed to encode payload for \(command.type)")
            return
        }
        webView.evaluateJavaScript(js) { [logger] _, error in
            if let error {
                logger.log("[BridgeSender] JS error: \(error)")
            }
        }
    }
}
