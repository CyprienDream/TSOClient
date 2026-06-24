import Foundation

// Renders a WireCommand as the JS expression that invokes
// window.TSOBridge.receive({type, payload}). Extracted from BridgeSender so
// the transport seam (evaluateJavaScript) and the wire-format seam (this)
// can be substituted independently.
protocol WireCommandJSSerializing {
    func serialize(_ command: WireCommand) -> String?
}

struct DefaultWireCommandJSSerializer: WireCommandJSSerializing {
    func serialize(_ command: WireCommand) -> String? {
        let payload = command.payload
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        let logLine: String = {
            guard let loggable = command as? LoggableCommand else { return "" }
            let safe = loggable.logSummary
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'",  with: "\\'")
            return "try { webkit.messageHandlers.logger.postMessage('[Swift→JS] \(safe)'); } catch(_) {}"
        }()
        return """
        (function(){
          \(logLine)
          if (window.TSOBridge) { window.TSOBridge.receive({type:'\(command.type)',payload:\(json)}); }
          else { try { webkit.messageHandlers.logger.postMessage('[Swift→JS] TSOBridge not ready'); } catch(_) {} }
        })()
        """
    }
}
