import Foundation

// JS-side handlers for these are registered in amf3-encoder.js.

struct DispatchSpecialistCommand: LoggableCommand {
    let uid1: Int
    let uid2: Int
    let actionType: Int
    let subTaskID: Int
    let targetGrid: Int

    var type: String { "DISPATCH_SPECIALIST" }
    var payload: [String: Any] {
        // JS handler reads opts.taskCode for the subTaskID slot.
        ["uid1": uid1, "uid2": uid2, "actionType": actionType, "taskCode": subTaskID, "targetGrid": targetGrid]
    }
    var logSummary: String {
        "DISPATCH uid=\(uid1):\(uid2) at=\(actionType) st=\(subTaskID) g=\(targetGrid)"
    }
}

struct DispatchBuffCommand: LoggableCommand {
    let buffUid1: Int
    let buffUid2: Int
    let targetGrid: Int

    var type: String { "DISPATCH_BUFF" }
    var payload: [String: Any] {
        ["buffUid1": buffUid1, "buffUid2": buffUid2, "targetGrid": targetGrid]
    }
    var logSummary: String {
        "DISPATCH_BUFF uid=\(buffUid1):\(buffUid2) g=\(targetGrid)"
    }
}
