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
    private let classifier = BuffCategoryClassifier(rules: [
        .buildingBuffs: BuffCategoryClassifier.Rule(
            prefixes: ["ProductivityBuff"],
            exact:    ["RemoveBuff", "HalloweenEvent_Horror"]
        )
    ])

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

    @Test func subtypeTimeBonusScalesEstimate() {
        // MasterExplorer (subTypeId 4, bonus=200) halves task time vs basic.
        // treasureShort: 21600 × 100 / 200 = 10800.
        let code = TaskCode(actionType: 1, subTaskID: 0)
        let basic   = ExplorerDurationRegistry.estimate(task: code, subTypeId: 1, skills: [])
        let premium = ExplorerDurationRegistry.estimate(task: code, subTypeId: 4, skills: [])
        #expect(basic == 21600)
        #expect(premium == 10800)
    }

    @Test func unknownSubtypeReturnsNil() {
        let code = TaskCode(actionType: 1, subTaskID: 0)
        #expect(ExplorerDurationRegistry.estimate(task: code, subTypeId: 9999, skills: []) == nil)
    }

    @Test func unknownTaskCodeReturnsNil() {
        let code = TaskCode(actionType: 7, subTaskID: 99)   // not in baseDurations
        #expect(ExplorerDurationRegistry.estimate(task: code, subTypeId: 1, skills: []) == nil)
    }

    @Test func skillScopeOnlyAppliesToMatchingTask() {
        // Pilgrimage (skillId=23, scope=treasure_long) lvl 3 → 15% reduction.
        // Should reduce treasureLong but not treasureShort or adventureLong.
        let skills = [SpecialistSkill(id: 23, level: 3)]
        let long  = TaskCode(actionType: 1, subTaskID: 2)
        let short = TaskCode(actionType: 1, subTaskID: 0)
        let adv   = TaskCode(actionType: 2, subTaskID: 2)
        let longUnreduced  = ExplorerDurationRegistry.estimate(task: long,  subTypeId: 1, skills: [])!
        let longReduced    = ExplorerDurationRegistry.estimate(task: long,  subTypeId: 1, skills: skills)!
        let shortUnreduced = ExplorerDurationRegistry.estimate(task: short, subTypeId: 1, skills: [])!
        let shortStill     = ExplorerDurationRegistry.estimate(task: short, subTypeId: 1, skills: skills)!
        let advUnreduced   = ExplorerDurationRegistry.estimate(task: adv,   subTypeId: 1, skills: [])!
        let advStill       = ExplorerDurationRegistry.estimate(task: adv,   subTypeId: 1, skills: skills)!

        #expect(longReduced < longUnreduced)
        #expect(abs(shortStill - shortUnreduced) < 0.0001)
        #expect(abs(advStill   - advUnreduced)   < 0.0001)
    }

    @Test func zeroLevelSkillsIgnored() {
        // Skill carried with level=0 must be a no-op.
        let code = TaskCode(actionType: 1, subTaskID: 0)
        let bare    = ExplorerDurationRegistry.estimate(task: code, subTypeId: 1, skills: [])
        let zeroed  = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: 1, skills: [SpecialistSkill(id: 36, level: 0)])
        #expect(bare == zeroed)
    }
}

@Suite("BuildingCategoryRegistry")
struct BuildingCategoryRegistryTests {

    @Test func loadDecodesFromMockResourceLoader() {
        let loader = MockResourceLoader()
        loader.setJSON("""
        [
          { "displayName": "Stone Mason", "skinBases": ["Mason"],   "group": "Masons" },
          { "displayName": "Copper Mine", "skinBases": ["BronzeMine"], "group": "Mines" }
        ]
        """, name: "building-categories")
        let registry = BuildingCategoryRegistry.load(loader: loader, logger: MockLogger())
        #expect(registry.categories.count == 2)
        #expect(registry.categories[0].displayName == "Stone Mason")
        #expect(registry.categories[1].skinBases == ["BronzeMine"])
    }

    @Test func missingFileReturnsEmpty() {
        let registry = BuildingCategoryRegistry.load(
            loader: MockResourceLoader(), logger: MockLogger())
        #expect(registry.categories.isEmpty)
    }

    @Test func malformedJSONReturnsEmpty() {
        let loader = MockResourceLoader()
        loader.setJSON("{ not json", name: "building-categories")
        let registry = BuildingCategoryRegistry.load(loader: loader, logger: MockLogger())
        #expect(registry.categories.isEmpty)
    }
}

@Suite("BuildingGroup.from")
struct BuildingGroupFromTests {

    @Test func mapsKnownRawValuesToCases() {
        #expect(BuildingGroup.from("Mines")       == .mines)
        #expect(BuildingGroup.from("Wood")        == .wood)
        #expect(BuildingGroup.from("Bookbinder")  == .bookbinder)
    }

    @Test func unknownAndNilFallToOther() {
        #expect(BuildingGroup.from(nil)           == .other)
        #expect(BuildingGroup.from("Mystery")     == .other)
        #expect(BuildingGroup.from("")            == .other)
    }
}

@Suite("BuffPanelConfig")
struct BuffPanelConfigTests {

    @Test func loadDecodesSubgroupsAndIgnoredLists() {
        let loader = MockResourceLoader()
        loader.setJSON("""
        {
          "subgroups": {
            "Stone Mason": "Aunt Irma's Feast",
            "Copper Mine": ""
          },
          "ignored": {
            "exact": ["WatchTower"],
            "containsCaseInsensitive": ["garrison"]
          }
        }
        """, name: "buff-panel-config")
        let cfg = BuffPanelConfig.load(loader: loader, logger: MockLogger())

        #expect(cfg.defaultBuffDisplayName(forSubgroup: "Stone Mason") == "Aunt Irma's Feast")
        #expect(cfg.defaultBuffDisplayName(forSubgroup: "Copper Mine") == "")
        #expect(cfg.defaultBuffDisplayName(forSubgroup: "Mystery") == nil)
    }

    @Test func shouldIgnoreMatchesExactAndCaseInsensitiveContains() {
        let cfg = BuffPanelConfig(
            subgroups: [:],
            ignoredExact: ["WatchTower"],
            ignoredContains: ["GARRISON"])

        #expect(cfg.shouldIgnore(skinBase: "WatchTower"))
        #expect(cfg.shouldIgnore(skinBase: "GreatHall_garrison"))   // case-insensitive
        #expect(!cfg.shouldIgnore(skinBase: "Mason"))
        #expect(!cfg.shouldIgnore(skinBase: "watchtower"))          // exact is case-sensitive
    }

    @Test func missingFileReturnsEmptyConfig() {
        let cfg = BuffPanelConfig.load(loader: MockResourceLoader(), logger: MockLogger())
        #expect(cfg.subgroups.isEmpty)
        #expect(!cfg.shouldIgnore(skinBase: "Anything"))
    }

    @Test func malformedJSONReturnsEmptyConfig() {
        let loader = MockResourceLoader()
        loader.setJSON("{not json", name: "buff-panel-config")
        let cfg = BuffPanelConfig.load(loader: loader, logger: MockLogger())
        #expect(cfg.subgroups.isEmpty)
    }
}
