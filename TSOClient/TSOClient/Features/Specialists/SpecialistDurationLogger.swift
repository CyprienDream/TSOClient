import Foundation

// Formats the [ExplorerDuration]/[GeologistDuration] log lines emitted by
// SpecialistDurationLearner. Extracted so the learner's responsibility stays
// "track wall-clock busy/idle transitions"; this type owns presentation.
struct SpecialistDurationLogger {
    let logger: Logger

    init(logger: Logger = ConsoleLogger()) {
        self.logger = logger
    }

    static func logPrefix(for kind: SpecialistKind) -> String? {
        switch kind {
        case .explorer:  return "ExplorerDuration"
        case .geologist: return "GeologistDuration"
        case .general, .unknown: return nil
        }
    }

    func busy(item: InboundMessage.SpecialistsPayload.Item,
              ct: Int, actionType: Int, subTaskId: Int, bonus: Int,
              pfbActive: Bool,
              formatter: SpecialistDisplayFormatter) {
        guard let prefix = Self.logPrefix(for: item.specialistType) else { return }
        let code = TaskCode(actionType: actionType, subTaskID: subTaskId)
        let skillStr = item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
        let realElapsedS = Double(ct) / 1000.0 * 100.0 / Double(bonus)
        let name = formatter.compactDisplayName(forPayloadItem: item)
        if let predicted = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: item.subTypeId, skills: item.skills, pfbActive: pfbActive) {
            let remainingS = max(0, predicted - realElapsedS)
            logger.log("[\(prefix)] busy \"\(name)\" uid=\(item.uid) type=\(item.subTypeId) " +
                       "task=\(actionType),\(subTaskId) skills=[\(skillStr)] " +
                       "predicted=\(Int(predicted))s elapsed=\(Int(realElapsedS))s " +
                       "remaining=\(Int(remainingS))s")
        } else {
            logger.log("[\(prefix)] busy \"\(name)\" uid=\(item.uid) type=\(item.subTypeId) " +
                       "task=\(actionType),\(subTaskId) skills=[\(skillStr)] " +
                       "elapsed=\(Int(realElapsedS))s")
        }
    }

    func idle(item: InboundMessage.SpecialistsPayload.Item,
              formatter: SpecialistDisplayFormatter) {
        guard let prefix = Self.logPrefix(for: item.specialistType) else { return }
        let skillStr = item.skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
        let name = formatter.compactDisplayName(forPayloadItem: item)
        logger.log("[\(prefix)] idle \"\(name)\" uid=\(item.uid) type=\(item.subTypeId) skills=[\(skillStr)]")
    }

    // Surface table errors: predicted vs observed should agree closely.
    // >5% divergence usually means a wrong timeBonus, a missing skill
    // mapping, or a missing base duration entry.
    func divergence(subTypeId: Int, actionType: Int, subTaskId: Int,
                    observedMs: Int, skills: [SpecialistSkill], pfbActive: Bool) {
        let code = TaskCode(actionType: actionType, subTaskID: subTaskId)
        guard let predicted = ExplorerDurationRegistry.estimate(
            task: code, subTypeId: subTypeId, skills: skills, pfbActive: pfbActive) else { return }
        let observedSec = Double(observedMs) / 1000.0
        let delta = abs(predicted - observedSec) / observedSec
        guard delta > 0.05 else { return }
        let key = "\(subTypeId):\(actionType):\(subTaskId)"
        let skillStr = skills.map { "\($0.id)/\($0.level)" }.joined(separator: ",")
        logger.log("[ExplorerDuration] divergence \(Int(delta*100))% " +
                   "key=\(key) skills=\(skillStr) " +
                   "predicted=\(Int(predicted))s observed=\(Int(observedSec))s")
    }
}
