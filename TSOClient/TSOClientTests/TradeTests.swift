import Testing
import Foundation
@testable import TSOClient

@Suite("TradeCoordinator")
struct TradeCoordinatorTests {

    private func makeCoord(recipients: RecipientsStore = RecipientsStore(),
                           dispatcher: CapturingDispatcher = CapturingDispatcher())
        -> (TradeCoordinator, CapturingDispatcher) {
        let coord = TradeCoordinator(
            recipients: recipients,
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

        coord.send()

        #expect(dispatcher.sent.count == 1)
        let cmd = dispatcher.sent[0] as? DispatchTradeCommand
        #expect(cmd?.receipientId == 1234)
        #expect(cmd?.offerResource == "Tool")
        #expect(cmd?.offerAmount == 100)
        #expect(cmd?.costsResource == "Wood")
        #expect(cmd?.costsAmount == 1)
        #expect(cmd?.slotType == 4)
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
