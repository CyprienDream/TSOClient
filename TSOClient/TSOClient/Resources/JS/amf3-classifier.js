(function() {
    'use strict';

    // Specialist classification: numeric subTypeId → canonical CamelCase name,
    // task VO class → kind, fallback rule for unknown numeric IDs, and a hint
    // learner that watches outbound type=95 dispatches so we can label idle
    // specialists on the next zone load.
    //
    // Subtype tables sourced from fedorovvl/tso_explorer_manager Loca.cs.
    // Generals: only basic variants confirmed (0 and 3 both observed in live
    // data). Premium variants are discovered the same way as explorers — the
    // scanner's unmapped logger surfaces any unknown subTypeId so they can be
    // added here.
    //
    // Public surface: window._tsoClassifier = { subtypeNameFor, classifyFromTask,
    // classifySpec, learnFromOutbound }.

    var EXPLORER_TYPES = {
        1: 'Explorer', 4: 'MasterExplorer', 10: 'EasterExplorer', 17: 'FastLuckyExplorer',
        28: 'IntrepidExplorer', 32: 'CorageousExplorer', 39: 'CandidExplorer',
        41: 'LovelyExplorer', 44: 'PrincessZoeExplorer', 46: 'Soccer2019Explorer',
        48: 'EmphaticExplorer', 51: 'BewitchingExplorer', 53: 'HumbleExplorer',
        55: 'KeenerExplorer', 58: 'BoldExplorer', 61: 'ScaredExplorer',
        65: 'SnowyExplorer', 66: 'RomanticExplorer', 68: 'MotherlyExplorer',
        69: 'BenevolentExplorer', 70: 'RoyalExplorer', 74: 'PirateExplorer',
        78: 'FluffyButteExplorer', 84: 'LoveStruckExplorer', 90: 'ChummyExplorer',
        94: 'GhostExplorer', 97: 'NoraExplorer',
    };
    var GEOLOGIST_TYPES = {
        2: 'Geologist', 5: 'JollyGeologist', 26: 'ConscientiousGeologist',
        34: 'IronWilledGeologist', 35: 'StoneColdGeologist', 38: 'VersedGeologist',
        40: 'LovelyGeologist', 42: 'GoldheartedGeologist', 45: 'ArcheologistGeologist',
        49: 'ThoroughGeologist', 59: 'DiligentGeologist', 62: 'ChummyGeologist',
        71: 'SophisticatedGeologist', 73: 'MummifiedGeologist', 76: 'GingerbreadGeologist',
        83: 'SootyGeologist', 86: 'BalancedGeologist', 98: 'TitanicGeologist',
    };
    var GENERAL_TYPES = {
        0: 'General', 3: 'General',
        13: 'MajorGeneral', 16: 'MasterOfMartialArtsGeneral',
        36: 'FieldMedicGeneral', 63: 'GhostGeneral', 93: 'SmugglerGeneral',
    };

    function subtypeNameFor(t) {
        if (EXPLORER_TYPES[t])  return EXPLORER_TYPES[t];
        if (GEOLOGIST_TYPES[t]) return GEOLOGIST_TYPES[t];
        if (GENERAL_TYPES[t])   return GENERAL_TYPES[t];
        return null;
    }

    // Derive specialist kind from the task VO class name — most reliable when busy.
    // FindDepositVO → Geologist. FindTreasureVO / FindEventZoneVO → Explorer.
    function classifyFromTask(taskObj) {
        if (!taskObj || !taskObj.__class) return null;
        var c = taskObj.__class;
        if (c.indexOf('FindDeposit') >= 0)   return 'Geologist';
        if (c.indexOf('FindTreasure') >= 0 ||
            c.indexOf('FindEventZone') >= 0)  return 'Explorer';
        return null;
    }

    // Classify specialist kind.
    // Priority: garrison check → Loca.cs subtype tables → numeric specialistType → name.
    // garrisonPos >= 0 is the authoritative General indicator (all Generals have a
    // garrison grid position; all Explorers/Geologists have -1).
    function classifySpec(t, garrisonPos, name) {
        if (garrisonPos >= 0) return 'General';
        if (EXPLORER_TYPES[t])  return 'Explorer';
        if (GEOLOGIST_TYPES[t]) return 'Geologist';
        if (t === 0) return 'General';
        if (t === 3) return 'General';
        var n = (name || '').toLowerCase();
        if (n.indexOf('geolog') >= 0)  return 'Geologist';
        if (n.indexOf('explor') >= 0)  return 'Explorer';
        if (n.indexOf('general') >= 0) return 'General';
        // Premium variant with unmapped numeric type. garrisonPos < 0 rules out
        // General, so default to Explorer — most premium drops are explorers
        // (e.g. Chummy/Ghost/LoveStruck/Nora Explorer). Misclassified Geologists
        // will surface via server-side errorCode on dispatch; numeric IDs are
        // logged in the scanner so EXPLORER_TYPES/GEOLOGIST_TYPES can be extended.
        return 'Explorer';
    }

    // Build uid→type hints from the game's own outbound type=95 dispatches.
    // actionType 0 → Geologist, 1/2 → Explorer, 12 → General.
    // Stored in window._tsoSpecTypeHints so it persists across specialist list updates.
    function learnFromOutbound(bodies) {
        try {
            for (var i = 0; i < bodies.length; i++) {
                var val = bodies[i].value;
                if (!Array.isArray(val)) continue;
                for (var j = 0; j < val.length; j++) {
                    var rmsg = val[j];
                    if (!rmsg || !rmsg.body) continue;
                    var bodyArr = rmsg.body;
                    if (!Array.isArray(bodyArr)) continue;
                    for (var k = 0; k < bodyArr.length; k++) {
                        var call = bodyArr[k];
                        if (!call || call.type !== 95 || !call.data) continue;
                        var action = call.data;
                        var taskData = action.data;
                        if (!taskData || !taskData.uniqueID) continue;
                        var uid1 = taskData.uniqueID.uniqueID1;
                        var uid2 = taskData.uniqueID.uniqueID2;
                        var uk = uid1 + ':' + uid2;
                        var aType = action.type;
                        var hint = aType === 0 ? 'Geologist'
                                 : (aType === 1 || aType === 2) ? 'Explorer'
                                 : aType === 12 ? 'General'
                                 : null;
                        if (hint && uk !== window._tsoOwnDispatch) {
                            if (!window._tsoSpecTypeHints) window._tsoSpecTypeHints = {};
                            window._tsoSpecTypeHints[uk] = hint;
                        }
                    }
                }
            }
        } catch (_) {}
    }

    window._tsoClassifier = {
        EXPLORER_TYPES:   EXPLORER_TYPES,
        GEOLOGIST_TYPES:  GEOLOGIST_TYPES,
        GENERAL_TYPES:    GENERAL_TYPES,
        subtypeNameFor:   subtypeNameFor,
        classifyFromTask: classifyFromTask,
        classifySpec:     classifySpec,
        learnFromOutbound: learnFromOutbound,
    };
})();
