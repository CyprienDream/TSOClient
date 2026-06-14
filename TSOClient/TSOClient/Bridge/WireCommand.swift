import Foundation

// A command Swift sends to JS via window.TSOBridge.receive({type, payload}).
// Wire contract only — no presentation concerns.
protocol WireCommand {
    var type: String { get }            // bridge "type" field, e.g. "DISPATCH_SPECIALIST"
    var payload: [String: Any] { get }  // bridge "payload" field, JSON-encodable
}

// Commands that contribute a short string to the [Swift→JS] log line. Optional —
// commands that don't conform render with just the bridge invocation.
protocol LoggableCommand: WireCommand {
    var logSummary: String { get }
}
