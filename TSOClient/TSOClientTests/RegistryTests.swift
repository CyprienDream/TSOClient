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

@Suite("GeologistDurationRegistry")
struct GeologistDurationRegistryTests {

    private static let sample = """
    {
      "baseDurations": {
        "0,0": 120, "0,1": 300, "0,2": 1800, "0,3": 3600,
        "0,4": 14400, "0,5": 14400, "0,6": 28800
      },
      "timeBonus": {
        "2":  100,
        "35": { "default": 100, "byTask": { "0,0": 200, "0,2": 200, "0,6": 200 } },
        "83": { "default": 100, "byTask": { "0,5": 133 } },
        "59": null
      },
      "skills": [
        { "name": "TendentiousGeologist", "skillId": 10, "scope": "minerals", "reduction": [10, 20, 30] },
        { "name": "OreCollector",         "skillId": 17, "scope": "ores",     "reduction": [10, 20, 30] }
      ]
    }
    """

    private static func loadSample() -> GeologistDurationRegistry.Loaded {
        let loader = MockResourceLoader()
        loader.setJSON(sample, name: "geologist-durations")
        return GeologistDurationRegistry.load(loader: loader, logger: MockLogger())
    }

    // Basic Geologist (subTypeId 2, bonus 100). Iron base 3600 → 3600 s.
    // PFB should shave 20% off → 2880 s. Sanity check that the production
    // static entry also loaded (via geologist-durations.json in Bundle.main).
    @Test func pfbReducesEstimateBy20Percent() {
        let code = TaskCode(actionType: 0, subTaskID: 3)
        let unbuffed = GeologistDurationRegistry.estimate(
            task: code, subTypeId: 2, skills: [], pfbActive: false)
        let buffed = GeologistDurationRegistry.estimate(
            task: code, subTypeId: 2, skills: [], pfbActive: true)
        #expect(unbuffed == 3600)
        #expect(abs((buffed ?? 0) - 2880) < 0.0001)
    }

    @Test func flatBonusFromLoadedSample() {
        let loaded = Self.loadSample()
        #expect(loaded.bonusFlat[2] == 100)
        #expect(loaded.bonusFlat[35] == nil)   // 35 is per-task, not flat
    }

    @Test func perTaskBonusHitsOverrideForListedTasks() {
        // StoneCold (subTypeId 35) — bonus 200 for stone/marble/granite, else 100.
        let stone   = TaskCode(actionType: 0, subTaskID: 0)
        let granite = TaskCode(actionType: 0, subTaskID: 6)
        let iron    = TaskCode(actionType: 0, subTaskID: 3)
        #expect(GeologistDurationRegistry.timeBonus(subTypeId: 35, task: stone)   == 200)
        #expect(GeologistDurationRegistry.timeBonus(subTypeId: 35, task: granite) == 200)
        #expect(GeologistDurationRegistry.timeBonus(subTypeId: 35, task: iron)    == 100)
    }

    @Test func perTaskBonusFallsBackToDefaultWhenTaskIsNil() {
        // Learner may query timeBonus before the task fields are unwrapped;
        // per-task subtypes must return their default in that case.
        #expect(GeologistDurationRegistry.timeBonus(subTypeId: 35, task: nil) == 100)
    }

    @Test func nullTimeBonusReturnsNilAndEstimateSkips() {
        // Diligent (59) has null bonus → unknown → no estimate.
        let code = TaskCode(actionType: 0, subTaskID: 4)
        #expect(GeologistDurationRegistry.timeBonus(subTypeId: 59, task: code) == nil)
        #expect(GeologistDurationRegistry.estimate(
            task: code, subTypeId: 59, skills: [], pfbActive: false) == nil)
    }

    @Test func mineralsSkillScopeAppliesOnlyToMineralTasks() {
        // Tendentious (id 10, scope minerals) lvl 3 → 30% reduction.
        // Stone (0,0) base 120 × 0.7 = 84 s. Iron (0,3) unchanged at 3600 s.
        let skills = [SpecialistSkill(id: 10, level: 3)]
        let stone = TaskCode(actionType: 0, subTaskID: 0)
        let iron  = TaskCode(actionType: 0, subTaskID: 3)
        let stoneReduced   = GeologistDurationRegistry.estimate(
            task: stone, subTypeId: 2, skills: skills, pfbActive: false)!
        let ironUnchanged  = GeologistDurationRegistry.estimate(
            task: iron,  subTypeId: 2, skills: skills, pfbActive: false)!
        #expect(abs(stoneReduced - 84) < 0.0001)
        #expect(ironUnchanged == 3600)
    }

    @Test func oresSkillScopeAppliesOnlyToOreTasks() {
        // OreCollector (id 17, scope ores) lvl 3 → 30% reduction.
        // Iron (0,3) 3600 × 0.7 = 2520 s. Stone (0,0) unchanged.
        let skills = [SpecialistSkill(id: 17, level: 3)]
        let stone = TaskCode(actionType: 0, subTaskID: 0)
        let iron  = TaskCode(actionType: 0, subTaskID: 3)
        let ironReduced = GeologistDurationRegistry.estimate(
            task: iron, subTypeId: 2, skills: skills, pfbActive: false)!
        let stoneUnchanged = GeologistDurationRegistry.estimate(
            task: stone, subTypeId: 2, skills: skills, pfbActive: false)!
        #expect(abs(ironReduced - 2520) < 0.0001)
        #expect(stoneUnchanged == 120)
    }

    @Test func unknownTaskCodeReturnsNil() {
        let bogus = TaskCode(actionType: 0, subTaskID: 42)
        #expect(GeologistDurationRegistry.estimate(
            task: bogus, subTypeId: 2, skills: [], pfbActive: false) == nil)
    }

    @Test func loadIgnoresNullTimeBonusEntries() {
        // JSON null for subTypeId 59 must be silently skipped, not decoded
        // as 0 or crash the loader.
        let loaded = Self.loadSample()
        #expect(loaded.bonusFlat[59] == nil)
        #expect(loaded.bonusDefault[59] == nil)
        #expect(loaded.bonusByTask[59] == nil)
    }

    @Test func missingFileReturnsEmpty() {
        let loaded = GeologistDurationRegistry.load(
            loader: MockResourceLoader(), logger: MockLogger())
        #expect(loaded.base.isEmpty)
        #expect(loaded.skills.isEmpty)
        #expect(loaded.bonusFlat.isEmpty)
    }

    @Test func malformedJSONReturnsEmpty() {
        let loader = MockResourceLoader()
        loader.setJSON("{ not json", name: "geologist-durations")
        let loaded = GeologistDurationRegistry.load(loader: loader, logger: MockLogger())
        #expect(loaded.base.isEmpty)
    }
}

@Suite("RegistryDurationEstimator routing")
struct RegistryDurationEstimatorRoutingTests {

    // actionType 1 (explorer treasureShort) must hit ExplorerDurationRegistry.
    @Test func explorerTaskGoesToExplorerRegistry() {
        let e = RegistryDurationEstimator()
        let short = TaskCode(actionType: 1, subTaskID: 0)
        #expect(e.estimate(task: short, subTypeId: 1, skills: [], pfbActive: false) == 21600)
    }

    // actionType 0 (geologist iron) must hit GeologistDurationRegistry.
    // Basic Geologist iron base 3600, bonus 100 → 3600 s.
    @Test func geologistTaskGoesToGeologistRegistry() {
        let e = RegistryDurationEstimator()
        let iron = TaskCode(actionType: 0, subTaskID: 3)
        #expect(e.estimate(task: iron, subTypeId: 2, skills: [], pfbActive: false) == 3600)
    }

    // The learner passes the task so per-task bonuses resolve correctly.
    @Test func timeBonusRoutingHonorsPerTaskOverride() {
        let e = RegistryDurationEstimator()
        // Sooty (83) coal (0,5) → 133; other tasks → default 100.
        let coal = TaskCode(actionType: 0, subTaskID: 5)
        let iron = TaskCode(actionType: 0, subTaskID: 3)
        #expect(e.timeBonus(subTypeId: 83, task: coal) == 133)
        #expect(e.timeBonus(subTypeId: 83, task: iron) == 100)
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
