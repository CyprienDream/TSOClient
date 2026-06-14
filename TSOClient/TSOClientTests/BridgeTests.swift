import Testing
import Foundation
@testable import TSOClient

private final class FakeHandler: InboundMessageHandler {
    let type: String
    private(set) var receivedPayloads: [Data] = []
    private let errorToThrow: Error?

    init(type: String, throws error: Error? = nil) {
        self.type = type
        self.errorToThrow = error
    }

    func apply(payloadData: Data) throws {
        receivedPayloads.append(payloadData)
        if let errorToThrow { throw errorToThrow }
    }
}

private struct BareCommand: WireCommand {
    let type: String
    let payload: [String: Any]
}

private struct EscapingLoggable: LoggableCommand {
    let type: String
    let payload: [String: Any]
    let logSummary: String
}

@Suite("InboundDispatcher")
struct InboundDispatcherTests {

    @Test func matchedTypeInvokesHandler() {
        let logger = MockLogger()
        let dispatcher = InboundDispatcher(logger: logger)
        let handler = FakeHandler(type: "BUFFS")
        dispatcher.register(handler)

        let body: [String: Any] = ["type": "BUFFS", "payload": ["items": [] as [Any]]]
        dispatcher.dispatch(name: "tso", body: body)

        #expect(handler.receivedPayloads.count == 1)
        #expect(logger.messages.isEmpty)
    }

    @Test func unknownTypeLogsAndDoesNotInvoke() {
        let logger = MockLogger()
        let dispatcher = InboundDispatcher(logger: logger)
        let handler = FakeHandler(type: "BUFFS")
        dispatcher.register(handler)

        dispatcher.dispatch(name: "tso", body: ["type": "MYSTERY", "payload": [:] as [String: Any]])

        #expect(handler.receivedPayloads.isEmpty)
        #expect(logger.messages.contains { $0.contains("no handler for type 'MYSTERY'") })
    }

    @Test func malformedBodyLogs() {
        let logger = MockLogger()
        let dispatcher = InboundDispatcher(logger: logger)
        dispatcher.register(FakeHandler(type: "BUFFS"))

        dispatcher.dispatch(name: "tso", body: "not a dict")
        #expect(logger.messages.contains { $0.contains("malformed") })
    }

    @Test func nonTSOChannelIgnored() {
        let logger = MockLogger()
        let dispatcher = InboundDispatcher(logger: logger)
        let handler = FakeHandler(type: "BUFFS")
        dispatcher.register(handler)

        dispatcher.dispatch(name: "logger", body: ["type": "BUFFS", "payload": [:] as [String: Any]])
        #expect(handler.receivedPayloads.isEmpty)
        #expect(logger.messages.isEmpty)
    }

    @Test func handlerErrorLogsButDoesNotCrash() {
        struct Boom: Error {}
        let logger = MockLogger()
        let dispatcher = InboundDispatcher(logger: logger)
        dispatcher.register(FakeHandler(type: "BUFFS", throws: Boom()))

        dispatcher.dispatch(name: "tso", body: ["type": "BUFFS", "payload": [:] as [String: Any]])
        #expect(logger.messages.contains { $0.contains("decode error for 'BUFFS'") })
    }

    @Test func registeringSameTypeTwiceReplacesHandler() {
        let dispatcher = InboundDispatcher(logger: MockLogger())
        let first = FakeHandler(type: "BUFFS")
        let second = FakeHandler(type: "BUFFS")
        dispatcher.register(first)
        dispatcher.register(second)

        dispatcher.dispatch(name: "tso", body: ["type": "BUFFS", "payload": [:] as [String: Any]])
        #expect(first.receivedPayloads.isEmpty)
        #expect(second.receivedPayloads.count == 1)
    }
}

@Suite("renderJSExpression")
struct RenderJSExpressionTests {

    // Note: the IIFE always contains a [Swift→JS] fallback log line for the
    // "TSOBridge not ready" branch. The per-command summary is what differs:
    // bare commands emit one [Swift→JS] occurrence (the fallback only);
    // loggable commands emit two (fallback + the actual summary).
    private func swiftToJSCount(_ js: String) -> Int {
        js.components(separatedBy: "[Swift→JS]").count - 1
    }

    @Test func bareCommandHasOnlyFallbackLogLine() throws {
        let cmd = BareCommand(type: "PING", payload: ["x": 1])
        let js = try #require(renderJSExpression(for: cmd))
        #expect(swiftToJSCount(js) == 1)
        #expect(js.contains("type:'PING'"))
        #expect(js.contains("\"x\":1"))
    }

    @Test func loggableCommandIncludesLogLine() throws {
        let cmd = EscapingLoggable(type: "PING", payload: [:], logSummary: "hello")
        let js = try #require(renderJSExpression(for: cmd))
        #expect(js.contains("[Swift→JS] hello"))
        #expect(swiftToJSCount(js) == 2)
    }

    @Test func logSummarySingleQuotesEscaped() throws {
        let cmd = EscapingLoggable(type: "PING", payload: [:], logSummary: "it's me")
        let js = try #require(renderJSExpression(for: cmd))
        // The single quote in "it's" must be backslash-escaped so it doesn't
        // terminate the JS string literal.
        #expect(js.contains("it\\'s me"))
    }

    @Test func logSummaryBackslashesEscaped() throws {
        let cmd = EscapingLoggable(type: "PING", payload: [:], logSummary: #"a\b"#)
        let js = try #require(renderJSExpression(for: cmd))
        // Backslash must be doubled for the JS string literal.
        #expect(js.contains(#"a\\b"#))
    }

    @Test func unencodablePayloadReturnsNil() {
        let cmd = BareCommand(type: "PING", payload: ["bad": Date()])  // Date is not JSON
        #expect(renderJSExpression(for: cmd) == nil)
    }

    @Test func dispatchSpecialistCommandHasExpectedShape() throws {
        let cmd = DispatchSpecialistCommand(uid1: 7, uid2: 9, actionType: 1, subTaskID: 3, targetGrid: 0)
        let js = try #require(renderJSExpression(for: cmd))
        #expect(js.contains("type:'DISPATCH_SPECIALIST'"))
        #expect(js.contains("\"uid1\":7"))
        #expect(js.contains("\"actionType\":1"))
        // Note: JS handler reads opts.taskCode for the subTaskID slot.
        #expect(js.contains("\"taskCode\":3"))
    }
}
