import SwiftUI

struct ContentView: View {
    @State private var env = AppEnvironment()
    @State private var activeTab: SideTab = .specialists

    enum SideTab { case specialists, buffs }

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/play")!, env: env)
                .frame(minWidth: 800, minHeight: 768)

            VStack(spacing: 0) {
                Picker("Tab", selection: $activeTab) {
                    Text("Specialists").tag(SideTab.specialists)
                    Text("Buffs").tag(SideTab.buffs)
                }
                .pickerStyle(.segmented)
                .padding(8)

                Divider()

                switch activeTab {
                case .specialists:
                    SpecialistsPanel(
                        store: env.specialists,
                        coordinator: env.specialistDispatch,
                        sender: env.sender
                    )
                case .buffs:
                    BuffsPanel(
                        buildingsStore: env.buildings,
                        buffsStore: env.buffs,
                        coordinator: env.buffDispatch
                    )
                }
            }
            .frame(width: 320)
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}
