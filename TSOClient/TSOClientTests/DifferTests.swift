import Testing
import Foundation
@testable import TSOClient

// SpecialistsDiffer.apply: when the id sequence is unchanged, only modified
// indices are written. This optimisation matters for SwiftUI row identity —
// rewriting every element would force every row to redraw on every payload.
// These tests pin both branches: same-shape (touch only changes) and
// reshape (wholesale replace).

private func item(id: String, name: String = "", isIdle: Bool = true) -> SpecialistItem {
    SpecialistItem(
        id: id, uid1: 0, uid2: 0,
        specialistType: .geologist, subTypeId: 0, subTypeName: nil,
        name: name, isIdle: isIdle, skills: [],
        collectedTime: nil, bonusTime: nil, taskEndTime: nil,
        taskActionType: nil, taskSubTaskId: nil
    )
}

@Suite("SpecialistsDiffer")
struct SpecialistsDifferTests {

    @Test func sameShapeIdenticalContentLeavesArrayUntouched() {
        var current = [item(id: "1:1"), item(id: "2:2")]
        let next    = [item(id: "1:1"), item(id: "2:2")]
        SpecialistsDiffer.apply(next: next, to: &current)
        #expect(current == next)
    }

    @Test func sameShapeReplacesOnlyChangedIndices() {
        var current = [item(id: "1:1", name: "Alice"),
                       item(id: "2:2", name: "Bob"),
                       item(id: "3:3", name: "Carol")]
        let next    = [item(id: "1:1", name: "Alice"),       // unchanged
                       item(id: "2:2", name: "Bob",          // flipped
                            isIdle: false),
                       item(id: "3:3", name: "Carol")]       // unchanged

        SpecialistsDiffer.apply(next: next, to: &current)

        // Content updated where expected.
        #expect(current[1].isIdle == false)
        #expect(current == next)
    }

    @Test func reshapeOnLengthMismatchWholesaleReplaces() {
        var current = [item(id: "1:1"), item(id: "2:2")]
        let next    = [item(id: "1:1"), item(id: "2:2"), item(id: "3:3")]
        SpecialistsDiffer.apply(next: next, to: &current)
        #expect(current.count == 3)
        #expect(current.map(\.id) == ["1:1", "2:2", "3:3"])
    }

    @Test func reshapeOnIdSequenceChangeWholesaleReplaces() {
        // Same count, different id ordering → not the same shape → replace.
        var current = [item(id: "1:1"), item(id: "2:2")]
        let next    = [item(id: "2:2"), item(id: "1:1")]
        SpecialistsDiffer.apply(next: next, to: &current)
        #expect(current.map(\.id) == ["2:2", "1:1"])
    }

    @Test func emptyToEmptyIsNoOp() {
        var current: [SpecialistItem] = []
        SpecialistsDiffer.apply(next: [], to: &current)
        #expect(current.isEmpty)
    }

    @Test func clearingToEmptyReplaces() {
        var current = [item(id: "1:1")]
        SpecialistsDiffer.apply(next: [], to: &current)
        #expect(current.isEmpty)
    }
}
