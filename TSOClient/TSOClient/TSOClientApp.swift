import SwiftUI

@main
struct TSOClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 900)
    }
}
