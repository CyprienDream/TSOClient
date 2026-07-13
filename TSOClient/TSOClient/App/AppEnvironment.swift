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
    let recipients: RecipientsStore
    let resources: ResourcesStore
    let publicTrades: PublicTradesStore
    let executor: WKWebViewJSExecutor     // late-binding webView holder
    let sender: BridgeSender              // produces JS via WireCommandJSSerializing
    let inbound: InboundDispatcher
    let specialistDispatch: SpecialistDispatchCoordinator
    let buffDispatch: BuffDispatchCoordinator
    let tradeCoordinator: TradeCoordinator
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
        self.buildings = BuildingsStore(logger: logger)
        self.buffs = BuffsStore(naming: naming)
        let recipients = RecipientsStore()
        self.recipients = recipients
        let resources = ResourcesStore(logger: logger)
        self.resources = resources
        let publicTrades = PublicTradesStore()
        self.publicTrades = publicTrades
        let executor = WKWebViewJSExecutor(logger: logger)
        self.executor = executor
        let sender = BridgeSender(logger: logger, executor: executor)
        self.sender = sender

        let specialistDispatch = SpecialistDispatchCoordinator(
            store: specialists, dispatcher: sender, logger: logger)
        self.specialistDispatch = specialistDispatch

        self.tradeCoordinator = TradeCoordinator(
            recipients: recipients, publicTrades: publicTrades,
            dispatcher: sender, logger: logger)

        let inbound = InboundDispatcher(logger: logger)
        inbound.register(CollectiblesHandler(store: collectibles))
        inbound.register(SpecialistsHandler(
            store: specialists, autoLoop: specialistDispatch, logger: logger))
        inbound.register(BuildingsHandler(store: buildings, logger: logger))
        inbound.register(BuffsHandler(store: buffs, logger: logger))
        inbound.register(PlayerBuffsHandler(store: specialists, logger: logger))
        inbound.register(FriendsHandler(store: recipients, logger: logger))
        inbound.register(GuildMembersHandler(store: recipients, logger: logger))
        inbound.register(ResourcesHandler(store: resources, logger: logger))
        inbound.register(PublicTradesHandler(store: publicTrades, logger: logger))
        inbound.register(GameStateHandler(
            stores: [collectibles, specialists, buildings, buffs, publicTrades],
            logger: logger
        ))
        // Buff panel activates on friend visits: BUILDINGS + BUFFS keep
        // flowing so the friend's buildings + our inventory populate, but
        // specialists and collectibles get wiped so their panels don't show
        // stale home data. See CLAUDE.md "Zone-context gate".
        inbound.register(ZoneContextHandler(
            offHomeStoresToClear: [specialists, collectibles],
            logger: logger
        ))
        self.inbound = inbound

        self.buffDispatch = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: sender,
            classifier: buffCategoryClassifier,
            bulk: BulkDispatcher(interCallDelayNs: 200_000_000),
            logger: logger)
    }
}
