import SwiftUI

struct ContentView: View {
    @State private var env = AppEnvironment()
    @State private var activeTab: SideTab = .specialists

    enum SideTab { case specialists, buffs, trade }

    var body: some View {
        HSplitView {
            WebView(
                url: URL(string: "https://www.thesettlersonline.com/en/play")!,
                executor: env.executor,
                inbound: env.inbound,
                logger: env.logger
            )
            .frame(minWidth: 800, minHeight: 768)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Tab", selection: $activeTab) {
                        Text("Specialists").tag(SideTab.specialists)
                        Text("Buffs").tag(SideTab.buffs)
                        Text("Trade").tag(SideTab.trade)
                    }
                    .pickerStyle(.segmented)

                    Button(action: { env.executor.reloadGame() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload game — resets RAM by tearing down Unity's heap + GL context")
                }
                .padding(8)

                Divider()

                switch activeTab {
                case .specialists:
                    SpecialistsPanel(store: env.specialists, coordinator: env.specialistDispatch)
                case .buffs:
                    BuffsPanel(
                        buildingsStore: env.buildings,
                        buffsStore: env.buffs,
                        coordinator: env.buffDispatch
                    )
                case .trade:
                    TradePanel(
                        recipientsStore: env.recipients,
                        resourcesStore: env.resources,
                        publicTradesStore: env.publicTrades,
                        coordinator: env.tradeCoordinator
                    )
                }
            }
            .frame(width: 320)
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}
