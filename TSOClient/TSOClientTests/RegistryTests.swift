import Testing
import Foundation
@testable import TSOClient

@Suite("NamingRegistry")
struct NamingRegistryTests {
    @Test func overrideWinsOverCamelCaseFallback() {
        let registry = NamingRegistry(
            specialistSubtypes: ["Soccer2019Explorer": "Adventurous Explorer"],
            buffs:              ["ProductivityBuffLvl3": "Aunt Irma's Basket"],
            buildings:          ["WoodCutter": "Pinewood Cutter"]
        )
        #expect(registry.specialistSubtypeOverride(raw: "Soccer2019Explorer") == "Adventurous Explorer")
        #expect(registry.buffName(raw: "ProductivityBuffLvl3") == "Aunt Irma's Basket")
        #expect(registry.buildingName(skinBase: "WoodCutter") == "Pinewood Cutter")
    }

    @Test func missingEntryFallsBackToCamelCaseSplit() {
        let registry = NamingRegistry.empty
        #expect(registry.specialistSubtypeOverride(raw: "PirateExplorer") == nil)
        #expect(registry.buffName(raw: "HiredMilitary") == "Hired Military")
        #expect(registry.buildingName(skinBase: "WatchTower") == "Watch Tower")
    }

    @Test func loadDecodesFromMockResourceLoader() {
        let loader = MockResourceLoader()
        loader.setJSON("""
        {
          "specialistSubtypes": { "Explorer": "Basic Explorer" },
          "buffs":              { "RemoveBuff": "Cleanse" },
          "buildings":          { "WoodCutter": "Pinewood Cutter" }
        }
        """, name: "naming")
        let registry = NamingRegistry.load(loader: loader, logger: MockLogger())
        #expect(registry.specialistSubtypeOverride(raw: "Explorer") == "Basic Explorer")
        #expect(registry.buffName(raw: "RemoveBuff") == "Cleanse")
    }

    @Test func missingFileReturnsEmptyAndLogs() {
        let loader = MockResourceLoader()
        let logger = MockLogger()
        let registry = NamingRegistry.load(loader: loader, logger: logger)
        #expect(registry.specialistSubtypes.isEmpty)
        #expect(logger.messages.contains { $0.contains("not found") })
    }

    @Test func malformedJSONReturnsEmptyAndLogs() {
        let loader = MockResourceLoader()
        loader.setJSON("{ not json", name: "naming")
        let logger = MockLogger()
        let registry = NamingRegistry.load(loader: loader, logger: logger)
        #expect(registry.specialistSubtypes.isEmpty)
        #expect(logger.messages.contains { $0.contains("decode error") })
    }
}

@Suite("BuffCategoryClassifier")
struct BuffCategoryClassifierTests {
    private let classifier = BuffCategoryClassifier(
        buildingBuffs: BuffCategoryClassifier.Rule(
            prefixes: ["ProductivityBuff"],
            exact:    ["RemoveBuff", "HalloweenEvent_Horror"]
        )
    )

    @Test func exactMatch() {
        #expect(classifier.isBuildingBuff("RemoveBuff"))
        #expect(classifier.isBuildingBuff("HalloweenEvent_Horror"))
    }

    @Test func prefixMatch() {
        #expect(classifier.isBuildingBuff("ProductivityBuffLvl3"))
        #expect(classifier.isBuildingBuff("ProductivityBuffLvl300"))
    }

    @Test func unrelatedNameRejected() {
        #expect(!classifier.isBuildingBuff("HiredMilitary"))
        #expect(!classifier.isBuildingBuff("AdventureBuff"))
        #expect(!classifier.isBuildingBuff(""))
    }

    @Test func emptyClassifierRejectsEverything() {
        let empty = BuffCategoryClassifier.empty
        #expect(!empty.isBuildingBuff("ProductivityBuffLvl3"))
        #expect(!empty.isBuildingBuff("RemoveBuff"))
    }
}
