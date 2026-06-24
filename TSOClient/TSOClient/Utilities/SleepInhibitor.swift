import Foundation

/// Holds a ProcessInfo activity token that prevents idle display sleep
/// for as long as the instance is alive — same mechanism browsers use
/// during video playback. Manual Energy Saver settings are not bypassed
/// when the lid is closed or the user explicitly sleeps the machine.
final class SleepInhibitor {
    private var token: NSObjectProtocol?

    func start(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
    }

    func stop() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit { stop() }
}
