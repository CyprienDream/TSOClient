(function() {
    'use strict';

    // ── Parser constructor ────────────────────────────────────────────────

    function AMFParser(buffer) {
        this.buf  = new Uint8Array(buffer);
        this.view = new DataView(buffer);
        this.pos  = 0;
        // AMF3 per-message reference tables
        this.str = [];   // string table
        this.obj = [];   // object table
        this.tr  = [];   // trait table
    }

    var P = AMFParser.prototype;

    // ── Primitives ────────────────────────────────────────────────────────

    P.u8    = function() { return this.buf[this.pos++]; };
    P.u16be = function() { var v = this.view.getUint16(this.pos, false); this.pos += 2; return v; };
    P.s32be = function() { var v = this.view.getInt32(this.pos,  false); this.pos += 4; return v; };
    P.f64be = function() { var v = this.view.getFloat64(this.pos, false); this.pos += 8; return v; };

    P.u29 = function() {
        var n = 0;
        for (var i = 0; i < 4; i++) {
            var b = this.u8();
            if (i < 3) { n = (n << 7) | (b & 0x7f); if (!(b & 0x80)) break; }
            else        { n = (n << 8) | b; }
        }
        return n;
    };

    P.utf8 = function(start, len) {
        return new TextDecoder().decode(this.buf.subarray(start, start + len));
    };

    // ── AMF0 ─────────────────────────────────────────────────────────────

    // Plain UTF-8 string with U16 length prefix (no type byte — used in envelope headers/bodies).
    P.amf0Str = function() {
        var len = this.u16be();
        var s   = this.utf8(this.pos, len);
        this.pos += len;
        return s;
    };

    P.amf0Val = function() {
        var t = this.u8();
        switch (t) {
            case 0x00: return this.f64be();
            case 0x01: return !!this.u8();
            case 0x02: return this.amf0Str();
            case 0x03: {                                          // Object
                var o = {};
                while (true) {
                    var k = this.amf0Str();
                    if (this.buf[this.pos] === 0x09) { this.pos++; break; }
                    o[k] = this.amf0Val();
                }
                return o;
            }
            case 0x05: return null;
            case 0x06: return undefined;
            case 0x08: {                                          // ECMA array
                this.s32be();                                     // count hint (ignored)
                var ea = {};
                while (true) {
                    var ek = this.amf0Str();
                    if (this.buf[this.pos] === 0x09) { this.pos++; break; }
                    ea[ek] = this.amf0Val();
                }
                return ea;
            }
            case 0x0A: {                                          // Strict array
                var n = this.s32be();
                var sa = [];
                for (var i = 0; i < n; i++) sa.push(this.amf0Val());
                return sa;
            }
            case 0x0B: { var ms = this.f64be(); this.u16be(); return new Date(ms); }
            case 0x0C: {                                          // Long string (U32 length)
                var ll = this.view.getUint32(this.pos, false); this.pos += 4;
                var ls = this.utf8(this.pos, ll); this.pos += ll;
                return ls;
            }
            case 0x11: return this.amf3Val();                     // AMF3 switch
            default:   throw new Error('AMF0 type 0x' + t.toString(16) + ' @' + (this.pos - 1));
        }
    };

    P.parseEnvelope = function() {
        this.pos = 2;                                             // skip version bytes 00 03
        var hc = this.u16be();
        for (var i = 0; i < hc; i++) {
            this.amf0Str(); this.u8(); this.s32be(); this.amf0Val();
        }
        var bc = this.u16be();
        var bodies = [];
        for (var j = 0; j < bc; j++) {
            var tgt  = this.amf0Str();
            var resp = this.amf0Str();
            this.s32be();
            bodies.push({ target: tgt, response: resp, value: this.amf0Val() });
        }
        return bodies;
    };

    // ── AMF3 ─────────────────────────────────────────────────────────────

    P.amf3Str = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.str[ref >> 1] || '';
        var len = ref >> 1;
        if (len === 0) return '';
        var s = this.utf8(this.pos, len);
        this.pos += len;
        this.str.push(s);
        return s;
    };

    P.amf3Val = function() {
        var t = this.u8();
        switch (t) {
            case 0x00: return undefined;
            case 0x01: return null;
            case 0x02: return false;
            case 0x03: return true;
            case 0x04: { var u = this.u29(); return (u & 0x10000000) ? u - 0x20000000 : u; }
            case 0x05: return this.f64be();
            case 0x06: return this.amf3Str();
            case 0x07: return this._xml();
            case 0x08: return this._date();
            case 0x09: return this._array();
            case 0x0A: return this._object();
            case 0x0B: return this._xml();
            case 0x0C: return this._byteArray();
            case 0x0D: return this._vecInt();
            case 0x0E: return this._vecUint();
            case 0x0F: return this._vecDouble();
            case 0x10: return this._vecObj();
            case 0x11: return this._dict();
            default:   throw new Error('AMF3 type 0x' + t.toString(16) + ' @' + (this.pos - 1));
        }
    };

    P._date = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var d = new Date(this.f64be());
        this.obj.push(d); return d;
    };

    P._xml = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var len = ref >> 1;
        var s = this.utf8(this.pos, len); this.pos += len;
        this.obj.push(s); return s;
    };

    P._byteArray = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var len = ref >> 1;
        var ba = this.buf.slice(this.pos, this.pos + len); this.pos += len;
        this.obj.push(ba); return ba;
    };

    P._array = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var dense = ref >> 1;
        var arr = [];
        this.obj.push(arr);
        while (true) { var k = this.amf3Str(); if (!k) break; arr[k] = this.amf3Val(); }
        for (var i = 0; i < dense; i++) arr.push(this.amf3Val());
        return arr;
    };

    P._object = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];

        var o = {};
        this.obj.push(o);

        var traits;
        if ((ref & 3) === 1) {                                   // trait reference
            traits = this.tr[ref >> 2];
        } else {                                                  // new trait
            var ext  = !!(ref & 4);
            var dyn  = !!(ref & 8);
            var nm   = ref >> 4;
            var cls  = this.amf3Str();
            var mems = [];
            for (var i = 0; i < nm; i++) mems.push(this.amf3Str());
            traits = { c: cls, m: mems, ext: ext, dyn: dyn };
            this.tr.push(traits);
        }

        o.__class = traits.c;

        if (traits.ext) { this._ext(o, traits.c); return o; }

        for (var j = 0; j < traits.m.length; j++) o[traits.m[j]] = this.amf3Val();

        if (traits.dyn) {
            while (true) { var dk = this.amf3Str(); if (!dk) break; o[dk] = this.amf3Val(); }
        }
        return o;
    };

    // Externalizable types known to TSO's Flex stack.
    P._ext = function(o, cls) {
        if (cls === 'flex.messaging.io.ArrayCollection' ||
            cls === 'mx.collections.ArrayCollection'    ||
            cls === 'flex.messaging.io.ObjectProxy'     ||
            cls === 'mx.utils.ObjectProxy') {
            o.source = this.amf3Val();
            return;
        }
        throw new Error('Unknown externalizable: ' + cls);
    };

    P._vecInt = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var n = ref >> 1; this.u8();
        var v = [];
        for (var i = 0; i < n; i++) { v.push(this.view.getInt32(this.pos, false)); this.pos += 4; }
        this.obj.push(v); return v;
    };

    P._vecUint = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var n = ref >> 1; this.u8();
        var v = [];
        for (var i = 0; i < n; i++) { v.push(this.view.getUint32(this.pos, false)); this.pos += 4; }
        this.obj.push(v); return v;
    };

    P._vecDouble = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var n = ref >> 1; this.u8();
        var v = [];
        for (var i = 0; i < n; i++) { v.push(this.view.getFloat64(this.pos, false)); this.pos += 8; }
        this.obj.push(v); return v;
    };

    P._vecObj = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var n = ref >> 1; this.u8(); this.amf3Str();
        var v = [];
        this.obj.push(v);
        for (var i = 0; i < n; i++) v.push(this.amf3Val());
        return v;
    };

    P._dict = function() {
        var ref = this.u29();
        if (!(ref & 1)) return this.obj[ref >> 1];
        var n = ref >> 1; this.u8();
        var d = {};
        this.obj.push(d);
        for (var i = 0; i < n; i++) { var k = this.amf3Val(); d[String(k)] = this.amf3Val(); }
        return d;
    };

    // ── Object-tree walker ────────────────────────────────────────────────
    //
    // Recurses into ByteArrays: Flex servers often nest the real VO inside a
    // ByteArray field of AcknowledgeMessage. We re-parse the ByteArray bytes
    // as a fresh AMF3 value and continue the search there.

    // Walk the entire object graph once and collect:
    //  - class name counts (diagnostic)
    //  - spawned-collectible instances (dBuildingVO with origin='cCollectibleBuilding')
    //  - the dZoneVO containing mapWidth/mapHeight
    //  - a uniqueID→gridIndex index (kept for future cross-reference needs;
    //    collectibles themselves resolve via their own buildingGrid field)
    //
    // Position field names vary by class:
    //   dBuildingVO.buildingGrid, dDepositVO.gridIdx, dLandscapeVO.grid,
    //   dResourceCreationVO.depositBuildingGridPos. Try in order.
    var POS_FIELDS = ['gridIndex', 'gridIdx', 'grid', 'buildingGrid', 'depositBuildingGridPos'];
    // dUniqueID appears under both 'uniqueID' (uppercase D) and 'uniqueId'
    // (lowercase d) depending on the owning class.
    var UID_FIELDS = ['uniqueID', 'uniqueId'];

    function detectPosition(v) {
        if (!v) return -1;
        for (var i = 0; i < POS_FIELDS.length; i++) {
            var n = v[POS_FIELDS[i]];
            if (typeof n === 'number' && n >= 0) return n;
        }
        return -1;
    }

    function uidObj(v) {
        if (!v) return null;
        for (var i = 0; i < UID_FIELDS.length; i++) {
            var u = v[UID_FIELDS[i]];
            if (u && typeof u === 'object') return u;
        }
        return null;
    }

    // dUniqueID is { uniqueID1: number, uniqueID2: number } — composite.
    // Each dUniqueID instance is a separate JS object after AMF3 decode, so
    // identity matching fails; we key by serialized value instead.
    function uidKey(u) {
        if (!u) return null;
        if (typeof u.uniqueID1 === 'number' && typeof u.uniqueID2 === 'number') {
            return u.uniqueID1 + ':' + u.uniqueID2;
        }
        return null;
    }

    // Skip ArrayCollection/ObjectProxy when picking the "meaningful parent"
    // so the pickup's parent reads as its containing dBuildingVO / dDepositVO
    // rather than the wrapper collection.
    function meaningfulParent(v) {
        return !!(v && v.__class &&
                  v.__class.indexOf('ArrayCollection') < 0 &&
                  v.__class.indexOf('ObjectProxy') < 0);
    }

    // Collectibles are dBuildingVO instances whose buildingName_string starts with
    // 'Collectible' (e.g. CollectibleHerbsBuilding, CollectibleBannerBuilding).
    // In the zone payload origin is a number (0/1), not the string
    // 'cCollectibleBuilding' that appears in DestructBuildingResultVO on pickup.
    function isCollectibleBuilding(v) {
        if (!v || !v.__class) return false;
        if (v.__class.split('.').pop() !== 'dBuildingVO') return false;
        var name = typeof v.buildingName_string === 'string' ? v.buildingName_string
                 : typeof v.skin === 'string' ? v.skin : '';
        return name.indexOf('Collectible') === 0;
    }

    function scanTree(v, depth, ctx, parent) {
        if (depth > 25 || v === null || v === undefined) return;
        if (typeof v !== 'object') return;
        if (ctx.seen.has(v)) return;
        ctx.seen.add(v);

        if (v instanceof Uint8Array && v.length > 4) {
            try {
                var bp = new AMFParser(v.slice().buffer);
                var bv = bp.amf3Val();
                scanTree(bv, depth + 1, ctx, parent);
            } catch(_) {}
            return;
        }

        if (Array.isArray(v)) {
            for (var i = 0; i < v.length; i++) scanTree(v[i], depth + 1, ctx, parent);
            return;
        }

        if (v.__class) {
            ctx.classes[v.__class] = (ctx.classes[v.__class] || 0) + 1;
            if (!ctx.exemplars[v.__class]) ctx.exemplars[v.__class] = v;
            var shortCls = v.__class.split('.').pop();
            if (shortCls === 'dBuildingVO') ctx.allBuildings.push(v);
            if (shortCls === 'DestructBuildingResultVO') ctx.destructed.push(v);
            if (shortCls === 'dSpecialistVO') ctx.specialists.push(v);
            // dServerActionResult.clientTime is the server-clock double, returned
            // in every response envelope. Snapshot the latest into ctx for the
            // SPECIALISTS payload; used as the reference for collectedTime conversion.
            if (shortCls === 'dServerActionResult' && typeof v.clientTime === 'number') {
                ctx.serverClock = v.clientTime;
            }
            // dPlayerVO: capture player level and collect full VO for buff inventory extraction.
            if (shortCls === 'dPlayerVO') {
                if (typeof v.playerLevel === 'number') ctx.playerLevel = v.playerLevel;
                ctx.playerVOs.push(v);
            }
            if (isCollectibleBuilding(v)) {
                ctx.items.push(v);
                ctx.itemParents.push(parent);
                if (!ctx.collectibleExemplar) ctx.collectibleExemplar = v;
            }
            // Index positioned objects by composite-uniqueID value so the
            // pickup can resolve its producing building/deposit via
            // (uniqueID1, uniqueID2) tuple lookup.
            var posVal = detectPosition(v);
            var uk     = uidKey(uidObj(v));
            if (posVal >= 0 && uk && !ctx.idToGrid[uk]) {
                ctx.idToGrid[uk] = { gi: posVal, cls: v.__class };
            }
        }

        // dZoneVO carries map dimensions. Match by suffix to be tolerant of
        // package paths; require both fields to be positive numbers.
        if (typeof v.mapWidth  === 'number' && v.mapWidth  > 0 &&
            typeof v.mapHeight === 'number' && v.mapHeight > 0) {
            ctx.maps.push({ w: v.mapWidth, h: v.mapHeight, cls: v.__class || '?' });
        }

        var nextParent = meaningfulParent(v) ? v : parent;

        if (v.source !== undefined) scanTree(v.source, depth + 1, ctx, nextParent);

        var keys = Object.keys(v);
        for (var k = 0; k < keys.length; k++) {
            var key = keys[k];
            if (key === '__class' || key === 'source') continue;
            scanTree(v[key], depth + 1, ctx, nextParent);
        }
    }

    function newCtx() {
        return {
            seen:         new WeakSet(),
            classes:      {},
            items:        [],
            itemParents:  [],
            maps:         [],
            exemplars:    {},
            idToGrid:     {},    // "uniqueID1:uniqueID2" → { gi, cls }
            allBuildings: [],    // every dBuildingVO, for calibration data export
            destructed:   [],    // DestructBuildingResultVO instances (pickup events)
            specialists:  [],    // dSpecialistVO instances
            playerVOs:    [],    // dPlayerVO instances (for buff inventory)
            serverClock:  null,  // dServerActionResult.clientTime (most recent in this response)
            playerLevel:  null,  // dPlayerVO.playerLevel (set on zone-load responses)
        };
    }

    function shortClass(c) { return c ? c.split('.').pop() : '?'; }

    // Derive specialist type from the task VO class name — most reliable when busy.
    // FindDepositVO → Geologist. FindTreasureVO / FindEventZoneVO → Explorer.
    function _classifyFromTask(taskObj) {
        if (!taskObj || !taskObj.__class) return null;
        var c = taskObj.__class;
        if (c.indexOf('FindDeposit') >= 0)   return 'Geologist';
        if (c.indexOf('FindTreasure') >= 0 ||
            c.indexOf('FindEventZone') >= 0)  return 'Explorer';
        return null;
    }

    // Numeric specialistType → canonical subtype name. Sourced from fedorovvl/
    // tso_explorer_manager Loca.cs (explorers / geologists dictionaries).
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
        83: 'SootyGeologist', 86: 'BalancedGeologist',
    };
    // Generals: only basic variants confirmed (0 and 3 both observed in live data).
    // Premium variants are discovered the same way as explorers — the unmapped logger
    // below surfaces any unknown subTypeId so they can be added here.
    var GENERAL_TYPES = {
        0: 'General', 3: 'General',
    };

    function _subtypeNameFor(t) {
        if (EXPLORER_TYPES[t])  return EXPLORER_TYPES[t];
        if (GEOLOGIST_TYPES[t]) return GEOLOGIST_TYPES[t];
        if (GENERAL_TYPES[t])   return GENERAL_TYPES[t];
        return null;
    }

    // Classify specialist type.
    // Priority: garrison check → Loca.cs subtype tables → numeric specialistType → name.
    // garrisonPos >= 0 is the authoritative General indicator (all Generals have a
    // garrison grid position; all Explorers/Geologists have -1).
    function _classifySpec(t, garrisonPos, name) {
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
        // logged below so EXPLORER_TYPES/GEOLOGIST_TYPES can be extended.
        return 'Explorer';
    }

    // ArrayCollection / ObjectProxy decode to { __class, source:[...] } here; bare arrays
    // pass through. Used for fields like dSpecialistVO.skills.
    function _unwrapCollection(v) {
        if (!v) return [];
        if (Array.isArray(v)) return v;
        if (Array.isArray(v.source)) return v.source;
        return [];
    }

    // Log every outbound dServerCall so unknown opcodes (e.g. buffs) surface in the console.
    function logAllOutboundCalls(bodies, channel) {
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
                        if (!call || !call.__class || call.__class.indexOf('dServerCall') < 0) continue;
                        var action = call.data;
                        webkit.messageHandlers.logger.postMessage(
                            '[AMF3:out:' + channel + '] callType=' + call.type +
                            ' zoneID=' + call.zoneID +
                            ' actionType=' + (action && action.type) +
                            ' actionGrid=' + (action && action.grid) +
                            ' data=' + JSON.stringify(action && action.data, null, 2).slice(0, 800));
                    }
                }
            }
        } catch (_) {}
    }

    // Build uid→type hints from the game's own outbound type=95 dispatches.
    // actionType 0 → Geologist, 1/2 → Explorer, 12 → General.
    // Stored in window._tsoSpecTypeHints so it persists across specialist list updates.
    function learnSpecialistTypes(bodies) {
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

    function buildResult(ctx) {
        var map = ctx.maps[0] || { w: _cachedMapWidth, h: _cachedMapHeight };
        if (map.w > 0) { _cachedMapWidth = map.w; _cachedMapHeight = map.h; }
        var items = [];
        for (var j = 0; j < ctx.items.length; j++) {
            var p = ctx.items[j];
            var gi = -1, src = '?';

            var ownPos = detectPosition(p);
            var uk     = uidKey(uidObj(p));

            if (ownPos >= 0) {
                gi = ownPos; src = 'self';
            } else if (uk && ctx.idToGrid[uk]) {
                var hit = ctx.idToGrid[uk];
                gi = hit.gi; src = 'uid' + uk + '→' + shortClass(hit.cls);
            } else {
                var par    = ctx.itemParents[j];
                var parPos = detectPosition(par);
                if (parPos >= 0) {
                    gi = parPos; src = 'parent→' + shortClass(par.__class);
                }
            }

            if (gi < 0) continue;
            // dBuildingVO uses 'skin' or 'buildingName_string' for its visual
            // identity; both observed equal e.g. "Warehouse" or
            // "DestroyableMountain_Mines_03". Prefer skin.
            items.push({
                gridIndex: gi,
                x: map.w > 0 ? gi % map.w : 0,
                y: map.w > 0 ? Math.floor(gi / map.w) : 0,
                assetName: (typeof p.skin === 'string')                ? p.skin
                         : (typeof p.buildingName_string === 'string') ? p.buildingName_string
                         : (typeof p.assetName === 'string')           ? p.assetName
                         : (p.__class || ''),
                posSource: src,
            });
        }
        return { mapWidth: map.w, mapHeight: map.h, items: items };
    }

    var _cachedMapWidth  = 0, _cachedMapHeight = 0;  // retained across pickup responses
    var _prevCollectibles = null;  // null until first zone-load; {gridIndex→item} thereafter

    // ── Analyze one AMF3 buffer ─────────────────────────────────────────
    // Called by both fetch and XHR interceptors. Extracts collectibles and
    // specialists from the response; logs type=95 acks and parse errors.
    function analyzeAMFBuffer(buf, channel) {
        var parser = new AMFParser(buf);
        var ctx = newCtx();
        var parsed = false;

        try {
            var bodies = parser.parseEnvelope();
            parsed = true;
            for (var i = 0; i < bodies.length; i++) {
                scanTree(bodies[i].value, 0, ctx);
                // Log acks for all dServerResponse types.
                // type=95 is specialist dispatch; unknown types (e.g. buffs) will surface here.
                (function(val) {
                    var msgs = Array.isArray(val) ? val : (val ? [val] : []);
                    msgs.forEach(function(msg) {
                        if (!msg) return;
                        var body = msg.body;
                        if (!body) return;
                        var sr = (body.__class && body.__class.indexOf('dServerResponse') >= 0) ? body : null;
                        if (!sr && body.data && body.data.__class && body.data.__class.indexOf('dServerResponse') >= 0) sr = body.data;
                        if (!sr) return;
                        webkit.messageHandlers.logger.postMessage(
                            '[AMF3:' + channel + '] ack type=' + sr.type +
                            ' errorCode=' + (sr.data && sr.data.errorCode) +
                            ' full=' + JSON.stringify(sr, null, 2).slice(0, 1500));
                    });
                })(bodies[i].value);
            }
        } catch (e) {
            try {
                var rp = new AMFParser(buf);
                scanTree(rp.amf3Val(), 0, ctx);
                parsed = true;
            } catch(_) {
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] parse error @pos=' + parser.pos + ': ' + e.message
                );
                return;
            }
        }
        if (!parsed) return;

        // Skip responses that carry no game-world data at all.
        // Settings/auth have none of these; destruct-only pickup responses have ctx.destructed.
        if (ctx.items.length === 0 && ctx.maps.length === 0 &&
            ctx.allBuildings.length === 0 && ctx.destructed.length === 0) return;

        // ── DestructBuildingResultVO: pickup with no full building list ────────
        // If the server sends only a destruct event (no updated building array),
        // handle it here and return — do NOT call setCollectibles([]) which would
        // clear the overlay markers.
        if (ctx.destructed.length > 0 && ctx.allBuildings.length === 0) {
            var d0 = ctx.destructed[0];

            // Try to extract a grid position from the VO or one level of nested objects.
            var dgi = detectPosition(d0);
            if (dgi < 0) {
                var dks = Object.keys(d0);
                for (var dki = 0; dki < dks.length && dgi < 0; dki++) {
                    var dkv = d0[dks[dki]];
                    if (dkv && typeof dkv === 'object' && !Array.isArray(dkv)) {
                        var dnested = detectPosition(dkv);
                        if (dnested >= 0) dgi = dnested;
                    }
                }
            }

            if (dgi >= 0 && _cachedMapWidth > 0) {
                var dKey = String(dgi);
                if (_prevCollectibles !== null && _prevCollectibles[dKey]) {
                    var updated = {};
                    Object.keys(_prevCollectibles).forEach(function(k) {
                        if (k !== dKey) updated[k] = _prevCollectibles[k];
                    });
                    _prevCollectibles = updated;
                }
            }
            return;
        }

        var result = buildResult(ctx);

        window._tsoSend('COLLECTIBLES', {
            mapWidth:  result.mapWidth,
            mapHeight: result.mapHeight,
            items:     result.items,
        });
        // setCollectibles already called above; don't call again here

        // Persist captured clock/player level even if no specialists in this response.
        // clientTime calibrated to ms (2026-05-23). Kept for potential future use
        // (e.g. recomputing remaining when collectedTime semantics change).
        if (typeof ctx.serverClock === 'number') {
            window._tsoServerClock = { serverTime: ctx.serverClock, capturedAtMs: Date.now() };
        }
        if (typeof ctx.playerLevel === 'number') {
            window._tsoPlayerLevel = ctx.playerLevel;
        }

        // ── Specialist extraction ─────────────────────────────────────────
        if (ctx.specialists.length > 0) {
            var specItems = [];
            for (var si = 0; si < ctx.specialists.length; si++) {
                var sp = ctx.specialists[si];
                var uid = uidObj(sp);
                var uk  = uidKey(uid);
                if (!uk) continue;
                var parts = uk.split(':');
                var u1 = parseInt(parts[0], 10);
                var u2 = parseInt(parts[1], 10);
                var taskObj = (sp.task != null) ? sp.task : null;
                var taskEnd = null;
                if (taskObj && typeof taskObj === 'object') {
                    var tf = taskObj.endTime || taskObj.finishTime || taskObj.timeToFinish || taskObj.taskEndTime;
                    if (tf instanceof Date) taskEnd = tf.getTime();
                    else if (typeof tf === 'number' && tf > 0) taskEnd = tf;
                }
                var taskTypeHint = _classifyFromTask(taskObj);
                if (taskTypeHint) {
                    if (!window._tsoSpecTypeHints) window._tsoSpecTypeHints = {};
                    window._tsoSpecTypeHints[uk] = taskTypeHint;
                }
                var hints = window._tsoSpecTypeHints;
                var subTypeId = (typeof sp.specialistType === 'number') ? sp.specialistType : -1;
                var spType = (hints && hints[uk])
                    || taskTypeHint
                    || _classifySpec(subTypeId, sp.garrisonBuildingGridPos | 0, sp.name_string);

                // Skills: ArrayCollection of SkillVO{id, level}. Emit IDs where level > 0.
                var skills = [];
                _unwrapCollection(sp.skills).forEach(function(sk) {
                    if (sk && typeof sk.id === 'number' && (sk.level | 0) > 0) skills.push(sk.id);
                });

                var collectedTime = (taskObj && typeof taskObj.collectedTime === 'number')
                    ? taskObj.collectedTime : null;
                var bonusTime = (taskObj && typeof taskObj.bonusTime === 'number')
                    ? taskObj.bonusTime : null;

                if (taskObj !== null) {
                    var _label = _subtypeNameFor(subTypeId) || spType;
                    if (sp.name_string) _label = sp.name_string + ' (' + _label + ')';
                    var _taskFields = Object.keys(taskObj).filter(function(k) { return k !== '__class'; }).map(function(k) {
                        var v = taskObj[k];
                        if (v instanceof Date) return k + '=Date(' + v.getTime() + ')';
                        if (v === null || v === undefined) return k + '=null';
                        if (typeof v === 'object') return k + '={' + Object.keys(v).slice(0,6).join(',') + '}';
                        return k + '=' + v;
                    }).join(' ');
                    webkit.messageHandlers.logger.postMessage(
                        '[AMF3:spec:timing] ' + _label + ' uid=' + uk +
                        ' serverClock=' + ctx.serverClock + ' | ' + _taskFields);
                }

                specItems.push({
                    uid: uk,
                    uid1: u1,
                    uid2: u2,
                    specialistType: spType,
                    subTypeId: subTypeId,
                    subTypeName: _subtypeNameFor(subTypeId),
                    name: sp.name_string || '',
                    isIdle: taskObj === null,
                    skills: skills,
                    collectedTime: collectedTime,
                    bonusTime: bonusTime,
                    taskEndTime: taskEnd,
                    taskActionType: (taskObj && typeof taskObj.type === 'number') ? taskObj.type : null,
                    taskSubTaskID:  (taskObj && typeof taskObj.subTaskID === 'number') ? taskObj.subTaskID : null,
                });
            }
            if (specItems.length > 0) {
                window._tsoSpecialists = specItems;
                window._tsoSend('SPECIALISTS', {
                    items: specItems,
                    playerLevel: (typeof window._tsoPlayerLevel === 'number') ? window._tsoPlayerLevel : null,
                    serverTime: (window._tsoServerClock && window._tsoServerClock.serverTime) || null,
                });
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] specialists=' + specItems.length +
                    ' level=' + (window._tsoPlayerLevel != null ? window._tsoPlayerLevel : '?'));
                // Diagnostic: surface premium variants whose numeric specialistType isn't
                // in EXPLORER_TYPES/GEOLOGIST_TYPES/GENERAL_TYPES so they can be added
                // (e.g. Chummy/Ghost/LoveStruck/Nora Explorer; premium Generals TBD).
                // Match name_string against in-game UI to learn the ID. One line per
                // zone load, only when unmapped exist.
                var unmapped = [];
                for (var ui = 0; ui < specItems.length; ui++) {
                    var sit = specItems[ui];
                    if (sit.subTypeId > 0 && !sit.subTypeName) {
                        unmapped.push('type=' + sit.subTypeId +
                                      ' cls=' + sit.specialistType +
                                      ' name="' + (sit.name || '') + '"' +
                                      ' idle=' + sit.isIdle +
                                      ' uid=' + sit.uid);
                    }
                }
                if (unmapped.length > 0) {
                    webkit.messageHandlers.logger.postMessage(
                        '[AMF3:spec:unmapped] ' + unmapped.length + ' premium variants:\n  ' +
                        unmapped.join('\n  '));
                }
            }
        }

        // ── Buildings extraction ──────────────────────────────────────────────
        // Only emit on full zone-load responses (those that also carried a dZoneVO
        // with map dimensions). Incremental update responses carry at most a handful
        // of buildings and should not replace the full list.
        if (ctx.maps.length > 0 && ctx.allBuildings.length > 0) {
            var buildingItems = [];
            var loggedExemplar = false;
            for (var bi = 0; bi < ctx.allBuildings.length; bi++) {
                var b = ctx.allBuildings[bi];
                var bGrid = detectPosition(b);
                if (bGrid < 0) continue;
                var bUid = uidObj(b);
                var bSkin = (typeof b.skin === 'string') ? b.skin
                          : (typeof b.buildingName_string === 'string') ? b.buildingName_string
                          : '';
                // Log the first non-collectible exemplar to discover all available fields.
                if (!loggedExemplar && bSkin.indexOf('Collectible') < 0) {
                    var bKeys = Object.keys(b).filter(function(k) { return k !== '__class'; });
                    var bFields = bKeys.map(function(k) {
                        var bv = b[k];
                        if (bv === null || bv === undefined) return k + '=null';
                        if (typeof bv === 'object') return k + '={cls:' + (bv.__class || '?') + '}';
                        return k + '=' + bv;
                    }).join(' | ');
                    webkit.messageHandlers.logger.postMessage(
                        '[AMF3:bldg:exemplar] skin=' + bSkin + ' | ' + bFields);
                    loggedExemplar = true;
                }
                // Extract the first currently-applied buff name on this building.
                var activeBuff = null;
                var bBuffList = _unwrapCollection(b.buffs);
                if (bBuffList.length > 0) {
                    var bf0 = bBuffList[0];
                    if (bf0 && typeof bf0.buffName_string === 'string') {
                        activeBuff = bf0.buffName_string;
                    } else if (!loggedExemplar) {
                        webkit.messageHandlers.logger.postMessage(
                            '[AMF3:bldg:buff] ' + JSON.stringify(bf0, null, 2).slice(0, 300));
                    }
                }
                loggedExemplar = true;
                buildingItems.push({
                    gridIndex:  bGrid,
                    skin:       bSkin,
                    uid1:       (bUid && typeof bUid.uniqueID1 === 'number') ? bUid.uniqueID1 : 0,
                    uid2:       (bUid && typeof bUid.uniqueID2 === 'number') ? bUid.uniqueID2 : 0,
                    activeBuff: activeBuff,
                });
            }
            if (buildingItems.length > 0) {
                window._tsoSend('BUILDINGS', { items: buildingItems });
                // Strip trailing _NNN level suffix to group by base type, then log sorted summary.
                var skinCounts = {};
                for (var si = 0; si < buildingItems.length; si++) {
                    var base = buildingItems[si].skin.replace(/_\d+$/, '');
                    skinCounts[base] = (skinCounts[base] || 0) + 1;
                }
                var skinSummary = Object.keys(skinCounts).sort().map(function(k) {
                    return k + ' x' + skinCounts[k];
                }).join('\n  ');
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:buildings] total=' + buildingItems.length + '\n  ' + skinSummary);
            }
        }

        // ── Buff inventory extraction ─────────────────────────────────────────
        // availableBuffs_vector lives on dPlayerVO. Emit BUFFS bridge message and
        // log a sample whenever the inventory is non-empty.
        for (var pi = 0; pi < ctx.playerVOs.length; pi++) {
            var pvo = ctx.playerVOs[pi];
            var buffList = _unwrapCollection(pvo.availableBuffs_vector);
            if (buffList.length === 0) continue;
            var buffItems = [];
            for (var bfi = 0; bfi < buffList.length; bfi++) {
                var bf = buffList[bfi];
                if (!bf) continue;
                buffItems.push({
                    uid1:         (typeof bf.uniqueId1 === 'number') ? bf.uniqueId1 : 0,
                    uid2:         (typeof bf.uniqueId2 === 'number') ? bf.uniqueId2 : 0,
                    buffName:     (typeof bf.buffName_string   === 'string') ? bf.buffName_string   : '',
                    resourceName: (typeof bf.resourceName_string === 'string') ? bf.resourceName_string : '',
                    amount:       (typeof bf.amount === 'number') ? bf.amount : 0,
                    insertedAt:   (typeof bf.insertedAt === 'number') ? bf.insertedAt : 0,
                });
            }
            if (buffItems.length > 0) {
                window._tsoSend('BUFFS', { items: buffItems });
                // Count instances per buff name for easy analysis.
                var buffCounts = {};
                for (var bci = 0; bci < buffItems.length; bci++) {
                    var bn = buffItems[bci].buffName || '(unknown)';
                    buffCounts[bn] = (buffCounts[bn] || 0) + 1;
                }
                var buffSummary = Object.keys(buffCounts).sort().map(function(k) {
                    return k + ' x' + buffCounts[k];
                }).join(', ');
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:buffs] total=' + buffItems.length + ' | ' + buffSummary);
            }
        }

        // Track current collectible set so DestructBuildingResultVO can remove the right entry.
        var currentSet = {};
        result.items.forEach(function(it) { currentSet[it.gridIndex] = it; });
        _prevCollectibles = currentSet;
    }

    // ── Fetch interception ──────────────────────────────────────────────
    var origFetch = window.fetch;
    window.fetch = function(input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';

        var isPost = init && (init.method || '').toUpperCase() === 'POST';
        if (isPost && init.body) {
            // Capture all POSTs — buff and other actions may use different URLs.
            captureOutboundBody(init.body, 'fetch');
            webkit.messageHandlers.logger.postMessage('[AMF3:out:url] POST ' + url.slice(0, 120));
        }
        // Always update realm URL so zone-shard changes are picked up automatically.
        if (url.includes('GameServer/amf')) {
            if (window._tsoRealmUrl !== url) {
                window._tsoRealmUrl = url;
                webkit.messageHandlers.logger.postMessage('[AMF3:url] realm updated: ' + url.slice(0, 120));
            }
        }

        return origFetch.apply(this, arguments).then(function(response) {
            var ct = response.headers ? (response.headers.get('content-type') || '') : '';
            var wantAMF = url.includes('GameServer') ||
                          ct.includes('amf') ||
                          ct.includes('octet-stream');
            if (wantAMF) {
                response.clone().arrayBuffer().then(function(buf) {
                    if (buf.byteLength > 3) analyzeAMFBuffer(buf, 'fetch');
                }).catch(function(e) {
                    webkit.messageHandlers.logger.postMessage('[AMF3:fetch] buffer error: ' + e);
                });
            } else if (ct.includes('json') || ct.includes('javascript')) {
                // Scan non-AMF JSON/JS responses once per URL for task config data.
                var scanKey = 'tsoCfgScanned:' + url;
                if (!window[scanKey]) {
                    window[scanKey] = true;
                    response.clone().text().then(function(text) {
                        var lower = text.toLowerCase();
                        var hasDuration = lower.indexOf('duration') >= 0 ||
                                         lower.indexOf('specialist') >= 0 ||
                                         lower.indexOf('explorer') >= 0 ||
                                         lower.indexOf('geologist') >= 0 ||
                                         lower.indexOf('tasktime') >= 0 ||
                                         lower.indexOf('task_time') >= 0 ||
                                         lower.indexOf('findtreasure') >= 0 ||
                                         lower.indexOf('findeventzone') >= 0;
                        if (hasDuration) {
                            webkit.messageHandlers.logger.postMessage(
                                '[AMF3:cfg] JSON hit: ' + url.slice(0, 200) +
                                ' | sample: ' + text.slice(0, 400));
                        }
                    }).catch(function(){});
                }
            }
            return response;
        });
    };

    // ── Auth context caching ─────────────────────────────────────────────
    // Walks a parsed outbound envelope to extract dsoAuthToken, DSId, zoneID, etc.
    // Called each time a GameServer POST is observed so zoneID stays current
    // across zone changes.
    function cacheAuthCtx(bodies) {
        try {
            for (var i = 0; i < bodies.length; i++) {
                var val = bodies[i].value;
                if (!Array.isArray(val)) continue;
                for (var j = 0; j < val.length; j++) {
                    var rmsg = val[j];
                    if (!rmsg || !rmsg.__class || rmsg.__class.indexOf('RemotingMessage') < 0) continue;
                    var dsId = (rmsg.headers && rmsg.headers.DSId) || '';
                    var bodyArr = rmsg.body;
                    if (!Array.isArray(bodyArr)) continue;
                    for (var k = 0; k < bodyArr.length; k++) {
                        var call = bodyArr[k];
                        if (!call || !call.__class || call.__class.indexOf('dServerCall') < 0) continue;
                        var prev = window._tsoAuthCtx;
                        // Track the game's outbound response counter so _TSORPC can
                        // continue the sequence rather than resetting to /1.
                        var seq = parseInt((bodies[i] && bodies[i].response || '/0').slice(1), 10);
                        if (seq > 0) window._tsoLastSeq = seq;
                        window._tsoAuthCtx = {
                            dsoAuthToken:          call.dsoAuthToken,
                            dsoAuthRandomClientID: call.dsoAuthRandomClientID,
                            dsoAuthUser:           call.dsoAuthUser,
                            zoneID:                call.zoneID,
                            DSId:                  dsId,
                        };
                        if (!prev || prev.zoneID !== call.zoneID) {
                            webkit.messageHandlers.logger.postMessage(
                                '[AMF3:auth] ctx updated zoneID=' + call.zoneID +
                                ' DSId=' + dsId.slice(0, 20));
                        }
                        return;
                    }
                }
            }
        } catch (_) {}
    }

    // ── Outbound body capture helper ────────────────────────────────────
    // Parses outbound AMF envelopes to refresh auth context and learn specialist types.
    function captureOutboundBody(body, channel) {
        function processBuf(buf) {
            try {
                var p = new AMFParser(buf);
                var bodies = p.parseEnvelope();
                cacheAuthCtx(bodies);
                learnSpecialistTypes(bodies);
            } catch (e) {
                webkit.messageHandlers.logger.postMessage('[AMF3:out] capture error: ' + e);
            }
        }
        function processBufWithLog(buf) {
            processBuf(buf);
            try {
                var p2 = new AMFParser(buf);
                logAllOutboundCalls(p2.parseEnvelope(), channel);
            } catch (_) {}
        }
        if (body instanceof ArrayBuffer) { processBufWithLog(body); return; }
        if (body instanceof Uint8Array)  { processBufWithLog(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)); return; }
        if (body instanceof Blob) { body.arrayBuffer().then(processBufWithLog).catch(function(){}); return; }
    }

    // ── XHR interception ────────────────────────────────────────────────
    // The fetch hook captured 30+ AMF responses but none carried the spawn
    // list — possible the game uses XHR for some calls. Hook open() to
    // remember the URL, then on load read the response as ArrayBuffer
    // (works for both responseType='arraybuffer' and binary string text).
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
        this._tsoUrl = url || '';
        this._tsoMethod = (method || '').toUpperCase();
        if (url && url.includes('GameServer/amf')) window._tsoRealmUrl = url;
        return origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function(body) {
        var xhr = this;
        // Capture all POSTs — buff and other actions may use different URLs.
        if (xhr._tsoMethod === 'POST' && body) {
            captureOutboundBody(body, 'xhr');
            webkit.messageHandlers.logger.postMessage('[AMF3:out:url] XHR POST ' + (xhr._tsoUrl || '?').slice(0, 120));
        }
        var wantResponse = xhr._tsoUrl && (
            xhr._tsoUrl.indexOf('GameServer') >= 0 ||
            xhr._tsoUrl.indexOf('amf') >= 0
        );
        if (wantResponse) {
            xhr.addEventListener('load', function() {
                try {
                    var buf = null;
                    if (xhr.response instanceof ArrayBuffer) {
                        buf = xhr.response;
                    } else if (typeof xhr.responseText === 'string' && xhr.responseText.length > 0) {
                        // Binary string fallback — each char is one byte.
                        var s = xhr.responseText;
                        var u8 = new Uint8Array(s.length);
                        for (var i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i) & 0xff;
                        buf = u8.buffer;
                    }
                    if (buf) analyzeAMFBuffer(buf, 'xhr');
                } catch (e) {
                    webkit.messageHandlers.logger.postMessage('[AMF3:xhr] handler error: ' + e);
                }
            });
        }
        return origSend.apply(this, arguments);
    };

    // Expose AMFParser for jsAMF3Encoder's response parsing.
    window._TSOAMFParser = AMFParser;
})();
