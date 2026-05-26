struct TaskCode: Equatable, Hashable {
    let actionType: Int  // → dServerAction.type
    let subTaskID: Int   // → dStartSpecialistTaskVO.subTaskID
}

// Deposit codes from fedorovvl/tso_client userscripts (valueMap '0,X' keys).
// actionType=0 for all geologist tasks. minLevel from 4-specialists.js geoDropSpec.req.
enum GeologistTask: Int, CaseIterable, Identifiable {
    case findStone     = 0
    case findBronzeOre = 1
    case findMarble    = 2
    case findIronOre   = 3
    case findGoldOre   = 4
    case findCoal      = 5
    case findGranite   = 6
    case findTitanium  = 7
    case findSalpeter  = 8

    var id: Int { rawValue }
    var taskCode: TaskCode { TaskCode(actionType: 0, subTaskID: rawValue) }

    var label: String {
        switch self {
        case .findStone:     return "Stone"
        case .findBronzeOre: return "Bronze Ore"
        case .findMarble:    return "Marble"
        case .findIronOre:   return "Iron Ore"
        case .findGoldOre:   return "Gold Ore"
        case .findCoal:      return "Coal"
        case .findGranite:   return "Granite"
        case .findTitanium:  return "Titanium"
        case .findSalpeter:  return "Salpeter"
        }
    }

    var minLevel: Int {
        switch self {
        case .findStone:     return 0
        case .findBronzeOre: return 9
        case .findMarble:    return 19
        case .findIronOre:   return 20
        case .findGoldOre:   return 23
        case .findCoal:      return 24
        case .findGranite:   return 60
        case .findTitanium:  return 61
        case .findSalpeter:  return 62
        }
    }

    func isAvailable(playerLevel: Int?) -> Bool {
        guard let lvl = playerLevel else { return true }
        return lvl >= minLevel
    }
}

// Task codes from fedorovvl/tso_client user_exp_time_matrix.js.
// Treasures: actionType=1, subTaskID=0..6.
// Adventures: actionType=2, subTaskID=0..3.
// requiredSkillID encodes the Explorer skill needed (39=Artefact, 40=BeanACollada).
enum ExplorerTask: CaseIterable, Identifiable {
    case treasureShort, treasureMedium, treasureLong, treasureVeryLong
    case treasureLongest, treasureErudite, treasureColada
    case adventureShort, adventureMedium, adventureLong, adventureVeryLong

    var id: String { label }
    var taskCode: TaskCode {
        switch self {
        case .treasureShort:     return TaskCode(actionType: 1, subTaskID: 0)
        case .treasureMedium:    return TaskCode(actionType: 1, subTaskID: 1)
        case .treasureLong:      return TaskCode(actionType: 1, subTaskID: 2)
        case .treasureVeryLong:  return TaskCode(actionType: 1, subTaskID: 3)
        case .treasureLongest:   return TaskCode(actionType: 1, subTaskID: 6)
        case .treasureErudite:   return TaskCode(actionType: 1, subTaskID: 4)
        case .treasureColada:    return TaskCode(actionType: 1, subTaskID: 5)
        case .adventureShort:    return TaskCode(actionType: 2, subTaskID: 0)
        case .adventureMedium:   return TaskCode(actionType: 2, subTaskID: 1)
        case .adventureLong:     return TaskCode(actionType: 2, subTaskID: 2)
        case .adventureVeryLong: return TaskCode(actionType: 2, subTaskID: 3)
        }
    }

    var label: String {
        switch self {
        case .treasureShort:     return "Treasure: Short"
        case .treasureMedium:    return "Treasure: Medium"
        case .treasureLong:      return "Treasure: Long"
        case .treasureVeryLong:  return "Treasure: Very Long"
        case .treasureLongest:   return "Treasure: Longest"
        case .treasureErudite:   return "Treasure: Erudite"
        case .treasureColada:    return "Treasure: Rarity Search"
        case .adventureShort:    return "Adventure: Short"
        case .adventureMedium:   return "Adventure: Medium"
        case .adventureLong:     return "Adventure: Long"
        case .adventureVeryLong: return "Adventure: Very Long"
        }
    }

    var requiredSkillID: Int? {
        switch self {
        case .treasureErudite: return 39
        case .treasureColada:  return 40
        default:               return nil
        }
    }

    func isAvailable(skills: [Int]) -> Bool {
        guard let req = requiredSkillID else { return true }
        return skills.contains(req)
    }
}

// General to star menu: actionType=12, subTaskID=0, grid=garrison grid index.
// From fedorovvl: SendServerAction(95, 12, S.GetGarrisonGridIdx(), 0, stask) where stask.subTaskID=0.
let generalStarMenuCode = TaskCode(actionType: 12, subTaskID: 0)
