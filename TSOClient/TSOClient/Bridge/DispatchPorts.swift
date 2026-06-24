import Foundation

// Domain-shaped dispatch contracts. Coordinators depend on these instead
// of the broader OutboundDispatching + wire-command construction. ISP:
// each coordinator's port is exactly the calls it needs; the coordinator
// stops needing to know the WireCommand struct shape.
protocol SpecialistDispatchPort {
    func dispatchSpecialist(uid1: Int,
                            uid2: Int,
                            actionType: Int,
                            subTaskID: Int,
                            targetGrid: Int)
}

protocol BuffDispatchPort {
    func dispatchBuff(buffUid1: Int,
                      buffUid2: Int,
                      targetGrid: Int)
}

// BridgeSender is the production conformer for both ports: it constructs
// the wire commands and sends them. Adapters could substitute in tests.
extension BridgeSender: SpecialistDispatchPort {
    func dispatchSpecialist(uid1: Int,
                            uid2: Int,
                            actionType: Int,
                            subTaskID: Int,
                            targetGrid: Int) {
        send(DispatchSpecialistCommand(
            uid1: uid1, uid2: uid2,
            actionType: actionType, subTaskID: subTaskID,
            targetGrid: targetGrid))
    }
}

extension BridgeSender: BuffDispatchPort {
    func dispatchBuff(buffUid1: Int, buffUid2: Int, targetGrid: Int) {
        send(DispatchBuffCommand(
            buffUid1: buffUid1, buffUid2: buffUid2,
            targetGrid: targetGrid))
    }
}
