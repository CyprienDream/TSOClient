import Foundation

// Replaces an items array with a new one, but only touches indices whose
// content actually changed when the id sequence is unchanged. Lifted from
// SpecialistsStore.apply so the store's contract becomes "swap items" and
// the SwiftUI-row-identity optimisation lives in one named place.
enum SpecialistsDiffer {
    static func apply(next: [SpecialistItem], to current: inout [SpecialistItem]) {
        let sameShape = current.count == next.count &&
            zip(current, next).allSatisfy { $0.id == $1.id }
        if sameShape {
            for idx in next.indices where current[idx] != next[idx] {
                current[idx] = next[idx]
            }
        } else {
            current = next
        }
    }
}
