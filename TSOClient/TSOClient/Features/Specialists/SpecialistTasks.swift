// Task codes confirmed from captured AMF traffic; adjust after Phase 1 capture.

enum GeologistTask: Int, CaseIterable, Identifiable {
    case findCoal     = 1
    case findIron     = 2
    case findGold     = 3
    case findTitanium = 4
    case findCopper   = 5
    case findGranite  = 6

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .findCoal:     return "Find Coal"
        case .findIron:     return "Find Iron"
        case .findGold:     return "Find Gold"
        case .findTitanium: return "Find Titanium"
        case .findCopper:   return "Find Copper"
        case .findGranite:  return "Find Granite"
        }
    }
}

enum ExplorerTask: Int, CaseIterable, Identifiable {
    case findTreasure  = 10
    case findAdventure = 11

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .findTreasure:  return "Find Treasure"
        case .findAdventure: return "Find Adventure"
        }
    }
}
