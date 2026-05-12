import SwiftUI

struct ContentView: View {
    @State private var store = CollectiblesStore()
    @State private var specialistsStore = SpecialistsStore()

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!,
                    store: store,
                    specialistsStore: specialistsStore)
                .frame(minWidth: 800, minHeight: 768)

            SpecialistsPanel(store: specialistsStore) { uid1, uid2, subTaskID, targetGrid in
                let js = """
                window._TSORPC?.dispatchSpecialist({
                    uid1:\(uid1),uid2:\(uid2),
                    taskCode:\(subTaskID),targetGrid:\(targetGrid)
                })
                """
                NotificationCenter.default.post(
                    name: .tsoEvaluateJS, object: nil,
                    userInfo: ["js": js])
            }
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}
