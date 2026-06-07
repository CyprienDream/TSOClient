import SwiftUI

struct ContentView: View {
    @State private var env = AppEnvironment()
    @State private var activeTab: SideTab = .specialists

    enum SideTab { case specialists, buffs }

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!, env: env)
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
                    SpecialistsPanel(store: env.specialists) { uid1, uid2, taskCode, targetGrid in
                        env.specialists.markDispatched(uid: "\(uid1):\(uid2)", actionType: taskCode.actionType, subTaskId: taskCode.subTaskID)
                        env.sender.send(DispatchSpecialistCommand(
                            uid1: uid1, uid2: uid2,
                            actionType: taskCode.actionType,
                            subTaskID: taskCode.subTaskID,
                            targetGrid: targetGrid))
                    }
                case .buffs:
                    BuffsPanel(
                        buildingsStore: env.buildings,
                        buffsStore: env.buffs
                    ) { buffUid1, buffUid2, targetGrid in
                        env.sender.send(DispatchBuffCommand(
                            buffUid1: buffUid1,
                            buffUid2: buffUid2,
                            targetGrid: targetGrid))
                    }
                }
            }
            .frame(width: 320)
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}
