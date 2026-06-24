import Foundation

// A command Swift sends to JS via window.TSOBridge.receive({type, payload}).
// Concrete commands are Encodable structs; the serializer encodes them with
// JSONEncoder so wire keys come from the struct's CodingKeys instead of a
// hand-rolled [String: Any] dictionary that can drift from the struct's
// field names.
protocol WireCommand: Encodable {
    var type: String { get }            // bridge "type" field, e.g. "DISPATCH_SPECIALIST"
}

// Commands that contribute a short string to the [Swift→JS] log line. Optional —
// commands that don't conform render with just the bridge invocation.
protocol LoggableCommand: WireCommand {
    var logSummary: String { get }
}
