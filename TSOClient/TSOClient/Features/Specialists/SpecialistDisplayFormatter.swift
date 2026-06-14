import Foundation

// Maps raw subtype names to in-game labels via the injected NamingRegistry.
// Some promo/event subtypes don't read well as a plain CamelCase split — e.g.
// "Soccer2019Explorer" shows as "Adventurous Explorer" in-game.
struct SpecialistDisplayFormatter {
    let naming: NamingRegistry

    init(naming: NamingRegistry = .default) {
        self.naming = naming
    }

    func displaySubtype(for item: SpecialistItem) -> String {
        if let raw = item.subTypeName, !raw.isEmpty {
            if let override = naming.specialistSubtypeOverride(raw: raw) { return override }
            return raw.camelCaseToWords
        }
        if item.subTypeId > 0 { return "\(item.specialistType.rawValue) #\(item.subTypeId)" }
        return item.specialistType.rawValue
    }

    func displayPrimary(for item: SpecialistItem) -> String {
        item.name.isEmpty ? displaySubtype(for: item) : item.name
    }

    func hasDistinctSecondary(for item: SpecialistItem) -> Bool {
        displayPrimary(for: item) != displaySubtype(for: item)
    }

    // Compact "Name (Subtype)" used in log lines; falls back to subtype alone
    // when no custom name is set.
    func compactDisplayName(forPayloadItem item: InboundMessage.SpecialistsPayload.Item) -> String {
        let raw = item.subTypeName ?? ""
        let subtype: String
        if let override = naming.specialistSubtypeOverride(raw: raw) { subtype = override }
        else if !raw.isEmpty { subtype = raw.camelCaseToWords }
        else { subtype = "\(item.specialistType.rawValue) #\(item.subTypeId)" }
        return item.name.isEmpty ? subtype : "\(item.name) (\(subtype))"
    }
}
