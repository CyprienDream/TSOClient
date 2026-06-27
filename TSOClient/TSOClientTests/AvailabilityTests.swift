import Testing
import Foundation
@testable import TSOClient

// SpecialistKindPolicy + SpecialistTaskAvailability — pure functions whose
// only previous coverage was indirect, through CoordinatorTests' bulk paths.

private func spec(kind: SpecialistKind, skills: [SpecialistSkill] = [],
                  isIdle: Bool = true,
                  taskAction: Int? = nil, taskSub: Int? = nil)
    -> SpecialistItem {
    SpecialistItem(
        id: "1:1", uid1: 1, uid2: 1,
        specialistType: kind, subTypeId: 0, subTypeName: nil,
        name: "", isIdle: isIdle, skills: skills,
        collectedTime: nil, bonusTime: nil, taskEndTime: nil,
        taskActionType: taskAction, taskSubTaskId: taskSub
    )
}

@Suite("SpecialistKind.defaultTaskCode")
struct SpecialistKindDefaultsTests {

    @Test func geologistDefaultsToFindStone() {
        #expect(SpecialistKind.geologist.defaultTaskCode == GeologistTask.findStone.taskCode)
    }

    @Test func explorerDefaultsToTreasureShort() {
        #expect(SpecialistKind.explorer.defaultTaskCode == ExplorerTask.treasureShort.taskCode)
    }

    @Test func generalAndUnknownDefaultToStarMenu() {
        #expect(SpecialistKind.general.defaultTaskCode == generalStarMenuCode)
        #expect(SpecialistKind.unknown.defaultTaskCode == generalStarMenuCode)
    }
}

@Suite("GeologistTask level gating")
struct GeologistTaskGatingTests {

    @Test func availableWhenPlayerLevelMeetsMinimum() {
        #expect(GeologistTask.findStone.isAvailable(playerLevel: 0))
        #expect(GeologistTask.findGranite.isAvailable(playerLevel: 60))
        #expect(GeologistTask.findGranite.isAvailable(playerLevel: 70))
    }

    @Test func unavailableBelowMinimum() {
        #expect(!GeologistTask.findGranite.isAvailable(playerLevel: 59))
        #expect(!GeologistTask.findTitanium.isAvailable(playerLevel: 60))
        #expect(!GeologistTask.findSalpeter.isAvailable(playerLevel: 61))
    }

    @Test func availableWhenLevelUnknown() {
        // Conservative default: if we don't know the level, don't hide tasks.
        #expect(GeologistTask.findGranite.isAvailable(playerLevel: nil))
    }
}

@Suite("ExplorerTask skill gating")
struct ExplorerTaskGatingTests {

    @Test func tasksWithoutRequiredSkillAreAlwaysAvailable() {
        #expect(ExplorerTask.treasureShort.isAvailable(skillIDs: []))
        #expect(ExplorerTask.adventureLong.isAvailable(skillIDs: []))
    }

    @Test func eruditeRequiresSkill39() {
        #expect(!ExplorerTask.treasureErudite.isAvailable(skillIDs: [22, 24, 36]))
        #expect(ExplorerTask.treasureErudite.isAvailable(skillIDs: [39]))
    }

    @Test func coladaRequiresSkill40() {
        #expect(!ExplorerTask.treasureColada.isAvailable(skillIDs: []))
        #expect(!ExplorerTask.treasureColada.isAvailable(skillIDs: [39]))
        #expect(ExplorerTask.treasureColada.isAvailable(skillIDs: [40]))
    }
}

@Suite("TaskCode.isAvailable(for:playerLevel:)")
struct TaskCodeAvailabilityTests {

    @Test func geologistDelegatesToLevelGate() {
        let s = spec(kind: .geologist)
        #expect(!GeologistTask.findGranite.taskCode.isAvailable(for: s, playerLevel: 30))
        #expect(GeologistTask.findGranite.taskCode.isAvailable(for: s, playerLevel: 60))
    }

    @Test func explorerDelegatesToSkillGate() {
        let withoutSkill = spec(kind: .explorer, skills: [])
        let withSkill    = spec(kind: .explorer, skills: [SpecialistSkill(id: 40, level: 3)])
        #expect(!ExplorerTask.treasureColada.taskCode.isAvailable(for: withoutSkill, playerLevel: nil))
        #expect(ExplorerTask.treasureColada.taskCode.isAvailable(for: withSkill, playerLevel: nil))
    }

    @Test func generalAlwaysAvailable() {
        let s = spec(kind: .general)
        #expect(generalStarMenuCode.isAvailable(for: s, playerLevel: nil))
        // Bizarre code still available — the General policy is unconditional.
        #expect(TaskCode(actionType: 99, subTaskID: 99).isAvailable(for: s, playerLevel: 1))
    }

    @Test func unknownKindAlwaysAvailable() {
        let s = spec(kind: .unknown)
        #expect(GeologistTask.findGranite.taskCode.isAvailable(for: s, playerLevel: 1))
    }
}

@Suite("SpecialistItem.currentTaskLabel")
struct CurrentTaskLabelTests {

    @Test func idleHasNoLabel() {
        #expect(spec(kind: .geologist, isIdle: true).currentTaskLabel == nil)
    }

    @Test func geologistShowsResourceName() {
        let s = spec(kind: .geologist, isIdle: false, taskAction: 0, taskSub: 4)
        #expect(s.currentTaskLabel == "Gold")
    }

    @Test func explorerShowsTaskLabel() {
        let s = spec(kind: .explorer, isIdle: false, taskAction: 1, taskSub: 2)
        #expect(s.currentTaskLabel == "Treasure: Long")
    }

    @Test func generalShowsStarMenuOnlyForMatchingCode() {
        let star  = spec(kind: .general, isIdle: false, taskAction: 12, taskSub: 0)
        let weird = spec(kind: .general, isIdle: false, taskAction: 99, taskSub: 9)
        #expect(star.currentTaskLabel == "Star Menu")
        // Non-matching code falls through to the raw "Task at/st" fallback.
        #expect(weird.currentTaskLabel == "Task 99/9")
    }

    @Test func unknownPolicyFallsBackToRawCode() {
        let s = spec(kind: .unknown, isIdle: false, taskAction: 1, taskSub: 1)
        #expect(s.currentTaskLabel == "Task 1/1")
    }
}

@Suite("GeologistTask.label(forPlayerLevel:)")
struct GeologistLabelTests {

    @Test func availableShowsBareLabel() {
        #expect(GeologistTask.findGranite.label(forPlayerLevel: 60) == "Granite")
    }

    @Test func gatedShowsRequiredLevelHint() {
        #expect(GeologistTask.findGranite.label(forPlayerLevel: 30) == "Granite (lvl 60)")
    }
}
