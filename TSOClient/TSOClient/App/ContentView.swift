import SwiftUI

struct ContentView: View {
    @State private var store = CollectiblesStore()
    @State private var specialistsStore = SpecialistsStore()
    @State private var sender = BridgeSender()

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!,
                    store: store,
                    specialistsStore: specialistsStore,
                    sender: sender)
                .frame(minWidth: 800, minHeight: 768)

            SpecialistsPanel(store: specialistsStore) { uid1, uid2, taskCode, targetGrid in
                specialistsStore.markDispatched(uid: "\(uid1):\(uid2)")
                sender.send(.dispatchSpecialist(
                    uid1: uid1, uid2: uid2,
                    actionType: taskCode.actionType,
                    subTaskID: taskCode.subTaskID,
                    targetGrid: targetGrid))
            }
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}
