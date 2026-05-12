import Observation

@Observable
final class SpecialistsStore {
    var items: [SpecialistItem] = []

    struct SpecialistItem: Identifiable {
        let id: String          // "uid1:uid2"
        let uid1: Int
        let uid2: Int
        let specialistType: String
        let name: String
        let level: Int
        let isIdle: Bool
        let taskEndTime: Double?
    }

    func apply(_ payload: InboundMessage.SpecialistsPayload) {
        items = payload.items.map {
            SpecialistItem(
                id: $0.uid,
                uid1: $0.uid1,
                uid2: $0.uid2,
                specialistType: $0.specialistType,
                name: $0.name,
                level: $0.level,
                isIdle: $0.isIdle,
                taskEndTime: $0.taskEndTime
            )
        }
    }

    func clear() { items = [] }
}
