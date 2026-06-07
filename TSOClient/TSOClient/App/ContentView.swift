import SwiftUI

struct ContentView: View {
    @State private var store = CollectiblesStore()
    @State private var specialistsStore = SpecialistsStore()
    @State private var buildingsStore = BuildingsStore()
    @State private var buffsStore = BuffsStore()
    @State private var sender = BridgeSender()
    @State private var activeTab: SideTab = .specialists

    enum SideTab { case specialists, buffs }

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!,
                    store: store,
                    specialistsStore: specialistsStore,
                    buildingsStore: buildingsStore,
                    buffsStore: buffsStore,
                    sender: sender)
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
                    SpecialistsPanel(store: specialistsStore) { uid1, uid2, taskCode, targetGrid in
                        specialistsStore.markDispatched(uid: "\(uid1):\(uid2)", actionType: taskCode.actionType, subTaskId: taskCode.subTaskID)
                        sender.send(.dispatchSpecialist(
                            uid1: uid1, uid2: uid2,
                            actionType: taskCode.actionType,
                            subTaskID: taskCode.subTaskID,
                            targetGrid: targetGrid))
                    }
                case .buffs:
                    BuffsPanel(
                        buildingsStore: buildingsStore,
                        buffsStore: buffsStore
                    ) { buffUid1, buffUid2, targetGrid in
                        sender.send(.dispatchBuff(
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
