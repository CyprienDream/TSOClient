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
