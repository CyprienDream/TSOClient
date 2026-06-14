import Foundation

// Decodes a single inbound message type and applies it. One handler per
// `type` string. Adding a new message type means writing a new handler
// and registering it on the dispatcher — no central switch to edit.
protocol InboundMessageHandler {
    var type: String { get }
    func apply(payloadData: Data) throws
}
