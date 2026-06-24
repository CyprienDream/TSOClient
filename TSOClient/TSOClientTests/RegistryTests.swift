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

@Suite("ExplorerDurationRegistry")
struct ExplorerDurationRegistryTests {
    // Basic explorer (subTypeId 1, bonus=100), no skills, treasureShort (1,0)
    // base=21600s. Without PFB → 21600s. With PFB → 21600 * 0.8 = 17280s.
    @Test func pfbReducesEstimateBy20Percent() {
        let code = TaskCode(actionType: 1, subTaskID: 0)
        let unbuffed = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: 1, skills: [], pfbActive: false)
        let buffed = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: 1, skills: [], pfbActive: true)
        #expect(unbuffed == 21600)
        #expect(buffed != nil)
        #expect(abs((buffed ?? 0) - 17280) < 0.0001)
    }

    @Test func pfbStacksMultiplicativelyWithSkillReduction() {
        // Pathfinder (skillId=36) level 3 → 15% reduction across all tasks.
        // treasureShort base 21600 × 0.85 = 18360, then × 0.8 PFB = 14688.
        let code = TaskCode(actionType: 1, subTaskID: 0)
        let skills = [SpecialistSkill(id: 36, level: 3)]
        let buffed = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: 1, skills: skills, pfbActive: true)
        #expect(buffed != nil)
        #expect(abs((buffed ?? 0) - 14688) < 0.0001)
    }
}
