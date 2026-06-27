import SwiftUI

// A dropdown-styled button that opens a popover containing a search field
// and a filtered, scrollable list of options. Used by TradePanel for both
// the recipient and resource pickers — friend / guild rosters and the
// trade-resource catalog can both grow large enough that scrolling a
// plain Menu is unpleasant.
struct SearchableMenu<ID: Hashable>: View {
    struct Option: Identifiable {
        let id: ID
        let title: String
    }

    let label: String
    let options: [Option]
    let onSelect: (ID) -> Void

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { opt in
                        Button {
                            onSelect(opt.id)
                            query = ""
                            isPresented = false
                        } label: {
                            Text(opt.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("No matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
        }
        .frame(width: 280, height: 320)
    }

    private var filtered: [Option] {
        guard !query.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}
