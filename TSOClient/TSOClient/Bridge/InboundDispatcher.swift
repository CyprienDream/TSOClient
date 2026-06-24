import Foundation

// Receives raw WKScriptMessage bodies and routes them to the handler registered
// for that message type. Decoding to a typed payload is the handler's job.
final class InboundDispatcher {
    private var handlers: [String: InboundMessageHandler] = [:]
    private let logger: Logger

    init(logger: Logger = ConsoleLogger()) {
        self.logger = logger
    }

    func register(_ handler: InboundMessageHandler) {
        handlers[handler.type] = handler
    }

    func dispatch(name: String, body: Any) {
        guard name == "tso" else { return }
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              let payload = dict["payload"] else {
            logger.log("[Inbound] malformed message: \(body)")
            return
        }
        // Look the handler up before serialising the payload — unknown
        // message types skip the JSONSerialization round-trip entirely.
        guard let handler = handlers[type] else {
            logger.log("[Inbound] no handler for type '\(type)'")
            return
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            logger.log("[Inbound] malformed message: \(body)")
            return
        }
        do {
            try handler.apply(payloadData: data)
        } catch {
            logger.log("[Inbound] decode error for '\(type)': \(error)")
        }
    }
}
