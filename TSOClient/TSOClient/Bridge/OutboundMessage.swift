import Foundation

// JS-side handlers for these are registered in amf3-encoder.js.

struct DispatchSpecialistCommand: LoggableCommand {
    let uid1: Int
    let uid2: Int
    let actionType: Int
    let subTaskID: Int
    let targetGrid: Int

    var type: String { "DISPATCH_SPECIALIST" }
    var logSummary: String {
        "DISPATCH uid=\(uid1):\(uid2) at=\(actionType) st=\(subTaskID) g=\(targetGrid)"
    }

    // JS handler reads opts.taskCode for the subTaskID slot — wire key
    // diverges from the Swift field name.
    enum CodingKeys: String, CodingKey {
        case uid1, uid2, actionType
        case subTaskID = "taskCode"
        case targetGrid
    }
}

struct DispatchTradeCommand: LoggableCommand {
    let receipientId: Int            // typo mirrors the wire field, do not "fix"
    let offerResource: String        // e.g. "Tool" — dResourceVO.name_string
    let offerAmount: Int
    let costsResource: String        // e.g. "Wood"
    let costsAmount: Int
    let lots: Int                    // trade-office bundle count; 0 for private trade
    let slotType: Int                // 4 = private trade, 0 = open-market

    var type: String { "DISPATCH_TRADE" }
    var logSummary: String {
        "DISPATCH_TRADE to=\(receipientId) " +
        "offer=\(offerAmount)x\(offerResource) costs=\(costsAmount)x\(costsResource) " +
        "lots=\(lots) slot=\(slotType)"
    }
}

struct CancelTradeCommand: LoggableCommand {
    let tradeId: Int                 // dTradeObjectVO.id from the 1062 snapshot

    var type: String { "CANCEL_TRADE" }
    var logSummary: String { "CANCEL_TRADE id=\(tradeId)" }
}

struct DispatchBuffCommand: LoggableCommand {
    let buffUid1: Int
    let buffUid2: Int
    let targetGrid: Int

    var type: String { "DISPATCH_BUFF" }
    var logSummary: String {
        "DISPATCH_BUFF uid=\(buffUid1):\(buffUid2) g=\(targetGrid)"
    }

    enum CodingKeys: String, CodingKey {
        case buffUid1, buffUid2, targetGrid
    }
}
