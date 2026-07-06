import Testing
import Foundation
@testable import TSOClient

@Suite("TradeCoordinator")
struct TradeCoordinatorTests {

    private func makeCoord(recipients: RecipientsStore = RecipientsStore(),
                           publicTrades: PublicTradesStore = PublicTradesStore(),
                           dispatcher: CapturingDispatcher = CapturingDispatcher())
        -> (TradeCoordinator, CapturingDispatcher) {
        let coord = TradeCoordinator(
            recipients: recipients,
            publicTrades: publicTrades,
            dispatcher: dispatcher,
            logger: MockLogger())
        return (coord, dispatcher)
    }

    @Test func defaultSelectionIsTheSeedBankPlayer() {
        let (coord, _) = makeCoord()
        #expect(coord.selectedRecipientID == TradeCoordinator.defaultRecipientID)
        #expect(coord.offerResource == "Tool")
        #expect(coord.costsResource == "Wood")
    }

    @Test func sendDispatchesPrivateTradeWithCurrentSelection() {
        let (coord, dispatcher) = makeCoord()
        coord.selectedRecipientID = 1234
        coord.offerResource = "Tool"
        coord.offerAmount   = 100
        coord.costsResource = "Wood"
        coord.costsAmount   = 1
        coord.lots          = 3 // must be ignored on private trade

        coord.send()

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchTradeCommand
        #expect(cmd?.receipientId == 1234)
        #expect(cmd?.offerResource == "Tool")
        #expect(cmd?.offerAmount == 100)
        #expect(cmd?.costsResource == "Wood")
        #expect(cmd?.costsAmount == 1)
        #expect(cmd?.lots == 0)
        #expect(cmd?.slotType == 4)
    }

    @Test func sendPublicDispatchesTradeOfficeOffer() {
        let (coord, dispatcher) = makeCoord()
        coord.selectedRecipientID = 1234 // must be ignored
        coord.offerResource = "BronzeSword"
        coord.offerAmount   = 133
        coord.costsResource = "Wood"
        coord.costsAmount   = 1
        coord.lots          = 2

        coord.sendPublic()

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchTradeCommand
        #expect(cmd?.receipientId == 0)
        #expect(cmd?.offerResource == "BronzeSword")
        #expect(cmd?.offerAmount == 133)
        #expect(cmd?.costsResource == "Wood")
        #expect(cmd?.costsAmount == 1)
        #expect(cmd?.lots == 2)
        // slotType=2 = "asking for a resource" category. Confirmed on wire
        // 2026-07-06 — the server rejects a resource-for-resource shape sent
        // as slotType=0 (that category expects a costsBuff, not costsRes).
        #expect(cmd?.slotType == 2)
    }

    @Test func sendReturnKeepsLotsZeroOnBothLegs() {
        let (coord, dispatcher) = makeCoord()
        coord.selectedRecipientID = 1234
        coord.lots = 4

        coord.sendReturn()

        #expect(dispatcher.sent.count == 2)
        let first  = dispatcher.sent[0] as? DispatchTradeCommand
        let second = dispatcher.sent[1] as? DispatchTradeCommand
        #expect(first?.lots == 0)
        #expect(second?.lots == 0)
        #expect(first?.slotType == 4)
        #expect(second?.slotType == 4)
    }

    @Test func sendPublicIgnoresRecipientRequirement() {
        let (coord, dispatcher) = makeCoord()
        coord.selectedRecipientID = 0 // canSend would be false; sendPublic still fires
        coord.sendPublic()
        #expect(dispatcher.sent.count == 1)
    }

    @Test func sendPublicRejectsOutOfRangeLots() {
        let (coord, dispatcher) = makeCoord()
        coord.lots = 5 // panel Stepper prevents this; guard the invariant anyway
        coord.sendPublic()
        #expect(dispatcher.sent.isEmpty)
        #expect(coord.lastSendStatus == "Fill in all fields.")
    }

    @Test func sendShowsValidationStatusWhenFieldsIncomplete() {
        let (coord, dispatcher) = makeCoord()
        coord.offerAmount = 0
        coord.send()
        #expect(dispatcher.sent.isEmpty)
        #expect(coord.lastSendStatus == "Fill in all fields.")
    }

    @Test func canSendRequiresAllFields() {
        let (coord, _) = makeCoord()
        #expect(coord.canSend == true)

        coord.offerResource = ""
        #expect(coord.canSend == false)
        coord.offerResource = "Tool"
        coord.costsAmount = 0
        #expect(coord.canSend == false)
        coord.costsAmount = 1
        coord.selectedRecipientID = 0
        #expect(coord.canSend == false)
    }

    @Test func statusUsesUsernameWhenRecipientKnown() {
        let recipients = RecipientsStore()
        recipients.applyFriends(.init(items: [
            .init(id: 999, username: "BankPlayer", level: 70, online: true)
        ]))
        let (coord, _) = makeCoord(recipients: recipients)
        coord.selectedRecipientID = 999
        coord.send()
        #expect(coord.lastSendStatus == "Sent to BankPlayer.")
    }

    @Test func statusFallsBackToIdWhenRecipientUnknown() {
        let (coord, _) = makeCoord()
        coord.selectedRecipientID = 4242
        coord.send()
        #expect(coord.lastSendStatus == "Sent to (id 4242).")
    }

    @Test func cancelDispatchesAndOptimisticallyRemovesFromStore() {
        let publicTrades = PublicTradesStore()
        publicTrades.apply(.init(items: [
            .init(id: 42761633, slotType: 2, slotPos: 0, type: 0,
                  offer: "Wood,1|EMEventResource,5|1",
                  remainingTime: 3_600_000, lotsRemaining: 1)
        ]))
        let (coord, dispatcher) = makeCoord(publicTrades: publicTrades)

        coord.cancel(tradeId: 42761633)

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? CancelTradeCommand
        #expect(cmd?.tradeId == 42761633)
        // Optimistic removal — the row disappears immediately; the next
        // 1062 snapshot reconfirms or restores it.
        #expect(publicTrades.items.isEmpty)
    }
}

@Suite("PublicTradesStore")
struct PublicTradesStoreTests {

    @Test func applyReplacesItemsAndSortsBySlot() {
        let store = PublicTradesStore()
        store.apply(.init(items: [
            .init(id: 3, slotType: 2, slotPos: 1, type: 0,
                  offer: "A|B|1", remainingTime: 0, lotsRemaining: 1),
            .init(id: 1, slotType: 0, slotPos: 0, type: 0,
                  offer: "C|D|1", remainingTime: 0, lotsRemaining: 1),
            .init(id: 2, slotType: 2, slotPos: 0, type: 0,
                  offer: "E|F|1", remainingTime: 0, lotsRemaining: 1),
        ]))
        #expect(store.items.map(\.tradeId) == [1, 2, 3])
    }

    @Test func applyDedupesByFingerprintSkipsVersionBump() {
        let store = PublicTradesStore()
        let payload = InboundMessage.PublicTradesPayload(items: [
            .init(id: 1, slotType: 0, slotPos: 0, type: 0,
                  offer: "X|Y|1", remainingTime: 100, lotsRemaining: 1)
        ])
        store.apply(payload)
        let v1 = store.version
        store.apply(payload)
        #expect(store.version == v1)
    }

    @Test func removeOptimisticallyDropsRow() {
        let store = PublicTradesStore()
        store.apply(.init(items: [
            .init(id: 42, slotType: 0, slotPos: 0, type: 0,
                  offer: "A|B|1", remainingTime: 0, lotsRemaining: 1)
        ]))
        store.remove(tradeId: 42)
        #expect(store.items.isEmpty)
    }

    @Test func clearWipesForZoneLifecycle() {
        let store = PublicTradesStore()
        store.apply(.init(items: [
            .init(id: 1, slotType: 0, slotPos: 0, type: 0,
                  offer: "A|B|1", remainingTime: 0, lotsRemaining: 1)
        ]))
        store.clear()
        #expect(store.items.isEmpty)
    }
}

@Suite("ResourcesStore")
struct ResourcesStoreTests {

    private func makeStore(initialFile: ResourcesStore.Persisted? = nil,
                           legacyNames: [String]? = nil)
        -> (ResourcesStore, MockJSONFileStore, MockKeyValueStore) {
        let fileStore = MockJSONFileStore()
        if let p = initialFile,
           let data = try? JSONEncoder().encode(p) {
            fileStore.files[ResourcesStore.persistenceFilename] = data
        }
        let legacy = MockKeyValueStore()
        if let names = legacyNames {
            legacy.set(names, forKey: "tso.tradeResources.wireConfirmed.v1")
        }
        let store = ResourcesStore(store: fileStore, legacyKV: legacy, logger: MockLogger())
        return (store, fileStore, legacy)
    }

    @Test func freshStoreSeedsFromCatalog() {
        let (store, _, _) = makeStore()
        // Curated entries are exposed with their display-name override; none confirmed yet.
        let corn = store.entries.first { $0.name == "Corn" }
        #expect(corn?.displayName == "Wheat")
        #expect(store.entries.allSatisfy { !$0.confirmed })
    }

    @Test func applyMarksWireConfirmedAndAddsUnknownNames() {
        let (store, fileStore, _) = makeStore()
        store.apply(.init(names: ["Tool", "MysteryResource"]))

        let tool = store.entries.first { $0.name == "Tool" }
        let mystery = store.entries.first { $0.name == "MysteryResource" }
        #expect(tool?.confirmed == true)
        #expect(mystery?.confirmed == true)
        #expect(mystery?.displayName == "Mystery Resource")
        // Wrote to the file store.
        #expect(fileStore.writes.contains { $0.filename == ResourcesStore.persistenceFilename })
    }

    @Test func applyWithNoNewNamesSkipsPersist() {
        let (store, fileStore, _) = makeStore()
        store.apply(.init(names: ["Tool"]))
        let writesAfterFirst = fileStore.writes.count

        // Re-applying the same name → no growth → no persist.
        store.apply(.init(names: ["Tool"]))
        #expect(fileStore.writes.count == writesAfterFirst)
    }

    @Test func loadsFromPersistedFileOnInit() {
        let persisted = ResourcesStore.Persisted(version: 1, names: ["Tool", "RareThing"])
        let (store, _, _) = makeStore(initialFile: persisted)
        let confirmed = store.entries.filter(\.confirmed).map(\.name)
        #expect(Set(confirmed) == ["Tool", "RareThing"])
    }

    @Test func migratesFromLegacyUserDefaultsAndClearsLegacyKey() {
        let (store, fileStore, legacy) = makeStore(legacyNames: ["Wood", "OldThing"])
        let confirmed = store.entries.filter(\.confirmed).map(\.name)
        #expect(Set(confirmed) == ["Wood", "OldThing"])
        // Migration writes the file once and clears the legacy slot.
        #expect(fileStore.writes.contains { $0.filename == ResourcesStore.persistenceFilename })
        #expect(legacy.object(forKey: "tso.tradeResources.wireConfirmed.v1") == nil)
    }

    @Test func entriesSortedByDisplayNameCaseInsensitive() {
        let (store, _, _) = makeStore()
        let displays = store.entries.map(\.displayName)
        let sorted   = displays.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(displays == sorted)
    }
}
