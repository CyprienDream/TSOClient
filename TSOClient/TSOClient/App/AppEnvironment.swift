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

    // Tees ConsoleLogger (Xcode console / unified log) and FileLogger (tailable
    // file under the sandbox container's Library/Logs/TSOClient/latest.log).
    // Cached as a static so the FileLogger is created exactly once per
    // process: a default-parameter factory would evaluate on every
    // AppEnvironment() construction, and SwiftUI builds View structs (hence
    // their @State initial values) multiple times — later constructions would
    // truncate the file and leave handlers from earlier constructions writing
    // to a closed FileHandle (swallowed by `try?`).
    static let defaultLogger: Logger = {
        let file = FileLogger()
        let tee = TeeLogger(loggers: [ConsoleLogger(), file])
        if let url = file.fileURL {
            tee.log("[FileLogger] writing to \(url.path)")
        }
        return tee
    }()

    init(logger: Logger = AppEnvironment.defaultLogger,
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
        inbound.register(SpecialistTaskCompletedHandler(
            store: specialists, autoLoop: specialistDispatch, logger: logger))
        // BuildingsHandler registered below, after buffDispatch exists — it
        // needs the coordinator as its BuffsAutoLoopRunner.
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

        let buffDispatch = BuffDispatchCoordinator(
            buffsStore: buffs,
            buildingsStore: buildings,
            dispatcher: sender,
            classifier: buffCategoryClassifier,
            bulk: BulkDispatcher(interCallDelayNs: 200_000_000),
            logger: logger,
            defaults: UserDefaultsKeyValueStore())
        self.buffDispatch = buffDispatch
        // Buff panel activates on friend visits: BUILDINGS + BUFFS keep
        // flowing so the friend's buildings + our inventory populate, but
        // specialists and collectibles get wiped so their panels don't show
        // stale home data. See CLAUDE.md "Zone-context gate". The
        // coordinator also gets notified so it can swap its per-category
        // buff selection map (home ↔ friend).
        inbound.register(ZoneContextHandler(
            offHomeStoresToClear: [specialists, collectibles],
            buffContext: buffDispatch,
            logger: logger
        ))
        inbound.register(BuildingsHandler(
            store: buildings, autoLoop: buffDispatch, logger: logger))
        self.inbound = inbound
    }
}
