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
            if (v.__class.split('.').pop() === 'dBuildingVO') ctx.allBuildings.push(v);
            if (v.__class.split('.').pop() === 'DestructBuildingResultVO') ctx.destructed.push(v);
            if (v.__class.split('.').pop() === 'dSpecialistVO') ctx.specialists.push(v);
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
        };
    }

    function shortClass(c) { return c ? c.split('.').pop() : '?'; }

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

    // Cross-call dedup: only log info that's NEW since the last call.
    // SEEN_CLASSES = full class names ever observed.
    // SEEN_ZONE_ARRAYS = dZoneVO array fields ever observed (key shapes).
    // LAST_PICKUP_COUNT = last numberOfGeneratedPickups value to spot changes.
    // LAST_BUILDING_COUNT = last dBuildingVO total to spot pickups/destructs.
    var SEEN_CLASSES = {};
    var SEEN_ZONE_ARRAYS = {};
    var LAST_PICKUP_COUNT = -1;
    var LAST_BUILDING_COUNT = -1;

    var _cachedMapWidth  = 0, _cachedMapHeight = 0;  // retained across pickup responses
    var _prevCollectibles = null;  // null until first zone-load; {gridIndex→item} thereafter

    // ── Analyze one AMF3 buffer ─────────────────────────────────────────
    // Called by both fetch and XHR interceptors. Quiet by default — logs
    // only when something new appears: previously-unseen classes, new
    // dZoneVO arrays, a change in numberOfGeneratedPickups, size-finder
    // hits, or successful pickup extraction.
    function analyzeAMFBuffer(buf, channel) {
        var parser = new AMFParser(buf);
        var ctx = newCtx();
        var parsed = false;

        try {
            var bodies = parser.parseEnvelope();
            parsed = true;
            for (var i = 0; i < bodies.length; i++) scanTree(bodies[i].value, 0, ctx);
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

        // Only log classes never seen before across the whole session.
        var newClasses = [];
        Object.keys(ctx.classes).forEach(function(c) {
            if (!SEEN_CLASSES[c]) {
                SEEN_CLASSES[c] = true;
                newClasses.push(shortClass(c) + 'x' + ctx.classes[c]);
            }
        });
        if (newClasses.length) {
            webkit.messageHandlers.logger.postMessage(
                '[AMF3:' + channel + '] new classes: ' + newClasses.sort().join(', ')
            );
        }

        // dBuildingVO total — pick up/destruct events make this decrement;
        // useful sanity signal that a response carried a building delta.
        var bldgCount = 0;
        Object.keys(ctx.classes).forEach(function(c) {
            if (shortClass(c) === 'dBuildingVO') bldgCount = ctx.classes[c];
        });
        if (bldgCount > 0 && bldgCount !== LAST_BUILDING_COUNT) {
            webkit.messageHandlers.logger.postMessage(
                '[AMF3:' + channel + '] dBuildingVO count: ' +
                LAST_BUILDING_COUNT + ' → ' + bldgCount
            );
            LAST_BUILDING_COUNT = bldgCount;
        }

        var zoneKey = Object.keys(ctx.exemplars).find(function(k) {
            return k.endsWith('dZoneVO');
        });
        if (zoneKey) {
            var zone = ctx.exemplars[zoneKey];

            // New dZoneVO array fields only (keyed by name+length+sample).
            var newArrFields = [];
            Object.keys(zone).forEach(function(k) {
                var f = zone[k];
                if (!f || typeof f !== 'object') return;
                var arr = Array.isArray(f) ? f
                        : (f.source && Array.isArray(f.source) ? f.source : null);
                if (!arr) return;
                var sample = arr.length > 0 && arr[0] && arr[0].__class
                             ? '<' + arr[0].__class.split('.').pop() + '>' : '';
                var sig = k + '[' + arr.length + ']' + sample;
                if (!SEEN_ZONE_ARRAYS[sig]) {
                    SEEN_ZONE_ARRAYS[sig] = true;
                    newArrFields.push(sig);
                }
            });
            if (newArrFields.length) {
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] new dZoneVO arrays: ' + newArrFields.join(', ')
                );
            }

            // Pickup-count change is the strongest signal that a spawn/despawn
            // happened. Always log on change; quiet otherwise.
            var pickupCount = (zone.pickupsDataVO && typeof zone.pickupsDataVO === 'object')
                              ? (zone.pickupsDataVO.numberOfGeneratedPickups | 0) : 0;
            if (pickupCount !== LAST_PICKUP_COUNT) {
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] numberOfGeneratedPickups: ' +
                    LAST_PICKUP_COUNT + ' → ' + pickupCount
                );
                LAST_PICKUP_COUNT = pickupCount;
            }

        }

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
            var dSrc = 'direct';
            if (dgi < 0) {
                var dks = Object.keys(d0);
                for (var dki = 0; dki < dks.length && dgi < 0; dki++) {
                    var dkv = d0[dks[dki]];
                    if (dkv && typeof dkv === 'object' && !Array.isArray(dkv)) {
                        var dnested = detectPosition(dkv);
                        if (dnested >= 0) { dgi = dnested; dSrc = dks[dki]; }
                    }
                }
            }

            if (dgi >= 0 && _cachedMapWidth > 0) {
                var dgx = dgi % _cachedMapWidth, dgy = Math.floor(dgi / _cachedMapWidth);
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] Destruct grid(' + dgx + ',' + dgy + ') gi=' + dgi + ' via ' + dSrc);
                var dKey = String(dgi);
                if (_prevCollectibles !== null && _prevCollectibles[dKey]) {
                    var updated = {};
                    Object.keys(_prevCollectibles).forEach(function(k) {
                        if (k !== dKey) updated[k] = _prevCollectibles[k];
                    });
                    _prevCollectibles = updated;
                } else {
                    webkit.messageHandlers.logger.postMessage(
                        '[AMF3:' + channel + '] Destruct gi=' + dgi +
                        ' not in prevCollectibles keys=[' + (_prevCollectibles ? Object.keys(_prevCollectibles).join(',') : 'null') + ']');
                }
            } else {
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] Destruct: no position field found');
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
                // taskEndTime: look for common field names; may be Date or numeric ms
                var endTime = null;
                var tet = sp.taskEndTime || sp.finishTime || sp.endTime || sp.taskFinishTime;
                if (tet instanceof Date) endTime = tet.getTime();
                else if (typeof tet === 'number' && tet > 0) endTime = tet;
                specItems.push({
                    uid: uk,
                    uid1: u1,
                    uid2: u2,
                    specialistType: sp.specialistType || sp.type || sp.specialistTypeID || 'Unknown',
                    name: sp.name || sp.specialistName || '',
                    level: sp.level || sp.skillLevel || 1,
                    isIdle: !sp.currentTask && !sp.task && endTime === null,
                    taskEndTime: endTime,
                });
            }
            if (specItems.length > 0) {
                window._tsoSend('SPECIALISTS', { items: specItems });
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:' + channel + '] specialists=' + specItems.length);
            }
        }

        // ── Pickup detection → calibration anchor ─────────────────────────
        // Compare current collectible set with previous. Exactly one disappearing
        // means a pickup; more disappearing means a zone change or bulk update.
        // We do NOT gate on ctx.maps.length because pickup responses can include
        // zone data (causing the old branch to treat them as zone-loads and skip
        // the diff entirely).
        var currentSet = {};
        result.items.forEach(function(it) { currentSet[it.gridIndex] = it; });

        _prevCollectibles = currentSet;

        webkit.messageHandlers.logger.postMessage(
            '[AMF3:' + channel + '] map=' + result.mapWidth + 'x' + result.mapHeight +
            ' pickups=' + result.items.length
        );
    }

    // ── Fetch interception ──────────────────────────────────────────────
    var origFetch = window.fetch;
    var _urlsSeen = {};
    window.fetch = function(input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';

        // One-shot URL log: first 20 unique game-server endpoints (skip static CDN assets).
        var isGameEndpoint = url.includes('thesettlersonline.com') &&
                             !url.includes('/frontend/') &&
                             !url.includes('/GFX_HASHED/');
        if (isGameEndpoint && Object.keys(_urlsSeen).length < 20 && !_urlsSeen[url]) {
            _urlsSeen[url] = true;
            webkit.messageHandlers.logger.postMessage('[AMF3:url] ' + url.slice(0, 120));
        }

        // ── Outbound body capture (Phase 1) ──────────────────────────────
        var isPost = init && (init.method || '').toUpperCase() === 'POST';
        if (url.includes('GameServer') && isPost && init.body) {
            captureOutboundBody(init.body, 'fetch');
        }
        // Store realm URL for _TSORPC to discover automatically.
        if (url.includes('GameServer/amf') && !window._tsoRealmUrl) {
            window._tsoRealmUrl = url;
            webkit.messageHandlers.logger.postMessage('[AMF3:url] realm cached: ' + url.slice(0, 100));
        }

        return origFetch.apply(this, arguments).then(function(response) {
            var ct = response.headers ? (response.headers.get('content-type') || '') : '';
            var wantAMF = url.includes('GameServer') ||
                          ct.includes('amf') ||
                          ct.includes('octet-stream');
            if (!wantAMF) return response;
            response.clone().arrayBuffer().then(function(buf) {
                if (buf.byteLength > 3) analyzeAMFBuffer(buf, 'fetch');
            }).catch(function(e) {
                webkit.messageHandlers.logger.postMessage('[AMF3:fetch] buffer error: ' + e);
            });
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
    function captureOutboundBody(body, channel) {
        function logBuf(buf) {
            try {
                var u8 = new Uint8Array(buf);
                // Hex dump first 512 bytes.
                var hex = '';
                var limit = Math.min(u8.length, 512);
                for (var i = 0; i < limit; i++) {
                    hex += ('0' + u8[i].toString(16)).slice(-2);
                    if ((i + 1) % 16 === 0) hex += '\n';
                    else hex += ' ';
                }
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:out:hex] len=' + u8.length + '\n' + hex.trim());
                // Parse as AMF3 envelope and pretty-print the tree.
                try {
                    var p = new AMFParser(buf);
                    var bodies = p.parseEnvelope();
                    webkit.messageHandlers.logger.postMessage(
                        '[AMF3:out] envelope target=' + (bodies[0] ? bodies[0].target : '?') +
                        ' response=' + (bodies[0] ? bodies[0].response : '?') +
                        ' tree=' + JSON.stringify(bodies, replacer, 2).slice(0, 2000));
                    cacheAuthCtx(bodies);
                } catch (pe) {
                    webkit.messageHandlers.logger.postMessage('[AMF3:out] parse fail: ' + pe.message);
                }
            } catch (e) {
                webkit.messageHandlers.logger.postMessage('[AMF3:out] capture error: ' + e);
            }
        }
        function replacer(k, v) {
            if (v instanceof Uint8Array) return '<ByteArray len=' + v.length + '>';
            if (v instanceof ArrayBuffer) return '<ArrayBuffer len=' + v.byteLength + '>';
            return v;
        }
        if (body instanceof ArrayBuffer) { logBuf(body); return; }
        if (body instanceof Uint8Array)  { logBuf(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)); return; }
        if (body instanceof Blob) { body.arrayBuffer().then(logBuf).catch(function(){}); return; }
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
        // Cache realm URL from first observed GameServer request.
        if (url && url.includes('GameServer/amf') && !window._tsoRealmUrl) {
            window._tsoRealmUrl = url;
        }
        return origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function(body) {
        var xhr = this;
        if (xhr._tsoUrl && xhr._tsoUrl.indexOf('GameServer') >= 0) {
            // Capture outbound body before sending.
            if (xhr._tsoMethod === 'POST' && body) {
                captureOutboundBody(body, 'xhr');
            }
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
