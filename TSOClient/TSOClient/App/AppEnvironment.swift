import Foundation

// Bag of the app's long-lived stores, bridge dispatchers, and view-model
// coordinators. Created once in ContentView and threaded through WebView so
// feature views don't accumulate per-store init parameters. Field types are
// reference types (@Observable classes), so passing by value preserves identity.
struct AppEnvironment {
    let collectibles: CollectiblesStore
    let specialists: SpecialistsStore
    let buildings: BuildingsStore
    let buffs: BuffsStore
    let executor: WKWebViewJSExecutor     // late-binding webView holder
    let sender: BridgeSender              // produces JS via WireCommandJSSerializing
    let inbound: InboundDispatcher
    let specialistDispatch: SpecialistDispatchCoordinator
    let buffDispatch: BuffDispatchCoordinator
    let logger: Logger

    init(logger: Logger = ConsoleLogger(),
         naming: NamingRegistry = .default,
         buffCategoryClassifier: BuffCategoryClassifier = .default) {
        self.logger = logger
        self.collectibles = CollectiblesStore()
        self.specialists = SpecialistsStore(
            formatter: SpecialistDisplayFormatter(naming: naming),
            learner: SpecialistDurationLearner(logger: logger)
        )
        self.buildings = BuildingsStore()
        self.buffs = BuffsStore(naming: naming)
        let executor = WKWebViewJSExecutor(logger: logger)
        self.executor = executor
        let sender = BridgeSender(logger: logger, executor: executor)
        self.sender = sender

        let specialistDispatch = SpecialistDispatchCoordinator(
            store: specialists, dispatcher: sender, logger: logger)
        self.specialistDispatch = specialistDispatch

        let inbound = InboundDispatcher(logger: logger)
        inbound.register(CollectiblesHandler(store: collectibles))
        inbound.register(SpecialistsHandler(
            store: specialists, autoLoop: specialistDispatch, logger: logger))
        inbound.register(BuildingsHandler(store: buildings, logger: logger))
        inbound.register(BuffsHandler(store: buffs, logger: logger))
        inbound.register(PlayerBuffsHandler(store: specialists, logger: logger))
        inbound.register(GameStateHandler(
            stores: [collectibles, specialists, buildings, buffs],
            logger: logger
        ))
        self.inbound = inbound

        self.buffDispatch = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: sender,
            classifier: buffCategoryClassifier,
            logger: logger)
    }
}
