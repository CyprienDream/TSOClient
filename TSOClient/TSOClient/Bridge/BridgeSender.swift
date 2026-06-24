import Observation

@Observable
final class BridgeSender: OutboundDispatching {
    private let logger: Logger
    private let serializer: WireCommandJSSerializing
    private let executor: JSExecutor

    init(logger: Logger = ConsoleLogger(),
         serializer: WireCommandJSSerializing = DefaultWireCommandJSSerializer(),
         executor: JSExecutor) {
        self.logger = logger
        self.serializer = serializer
        self.executor = executor
    }

    func send(_ command: WireCommand) {
        guard let js = serializer.serialize(command) else {
            logger.log("[BridgeSender] failed to encode payload for \(command.type)")
            return
        }
        executor.evaluate(js)
    }
}
