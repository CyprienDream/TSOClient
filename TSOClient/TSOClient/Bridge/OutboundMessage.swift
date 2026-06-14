import Foundation

// JS-side handlers for these are registered in amf3-encoder.js.

struct DispatchSpecialistCommand: LoggableCommand {
    let uid1: Int
    let uid2: Int
    let actionType: Int
    let subTaskID: Int
    let targetGrid: Int

    var type: String { "DISPATCH_SPECIALIST" }
    var payload: [String: Any] {
        // JS handler reads opts.taskCode for the subTaskID slot.
        ["uid1": uid1, "uid2": uid2, "actionType": actionType, "taskCode": subTaskID, "targetGrid": targetGrid]
    }
    var logSummary: String {
        "DISPATCH uid=\(uid1):\(uid2) at=\(actionType) st=\(subTaskID) g=\(targetGrid)"
    }
}

struct DispatchBuffCommand: LoggableCommand {
    let buffUid1: Int
    let buffUid2: Int
    let targetGrid: Int

    var type: String { "DISPATCH_BUFF" }
    var payload: [String: Any] {
        ["buffUid1": buffUid1, "buffUid2": buffUid2, "targetGrid": targetGrid]
    }
    var logSummary: String {
        "DISPATCH_BUFF uid=\(buffUid1):\(buffUid2) g=\(targetGrid)"
    }
}

// Renders the IIFE that posts a log line and invokes window.TSOBridge.receive.
// Escaping: summary is single-quoted in JS; backslashes and single quotes
// in summary are escaped. payload is JSON, so embedded quotes are already safe.
func renderJSExpression(for command: WireCommand) -> String? {
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
