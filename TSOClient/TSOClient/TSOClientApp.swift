import SwiftUI

@main
struct TSOClientApp: App {
    private let sleepInhibitor: SleepInhibitor = {
        let inhibitor = SleepInhibitor()
        inhibitor.start(reason: "TSO automation loop running")
        return inhibitor
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 900)
    }
}
