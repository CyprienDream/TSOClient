(function() {
    'use strict';

    // Object-tree walker + per-VO extractors. Takes a parsed AMF envelope and
    // emits COLLECTIBLES / SPECIALISTS / BUILDINGS / BUFFS bridge messages.
    //
    // Depends on:
    //   window._TSOAMFParser  (defined by amf3-parser.js — used to re-parse ByteArray VOs)
    //   window._tsoClassifier (defined by amf3-classifier.js — subtype + classification)
    //
    // Public surface: window._tsoScanner = { analyzeAMFBuffer }. The net
    // interceptor (amf3-net.js) is the only caller.

    var AMFParser  = window._TSOAMFParser;
    var classifier = window._tsoClassifier;

    // ── Walker helpers ────────────────────────────────────────────────────
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

    // ArrayCollection / ObjectProxy decode to { __class, source:[...] } here; bare arrays
    // pass through. Used for fields like dSpecialistVO.skills.
    function unwrapCollection(v) {
        if (!v) return [];
        if (Array.isArray(v)) return v;
        if (Array.isArray(v.source)) return v.source;
        return [];
    }

    function shortClass(c) { return c ? c.split('.').pop() : '?'; }

    // Walk the entire object graph once and collect:
    //  - class name counts (diagnostic)
    //  - spawned-collectible instances (dBuildingVO with origin='cCollectibleBuilding')
    //  - the dZoneVO containing mapWidth/mapHeight
    //  - a uniqueID→gridIndex index (kept for future cross-reference needs;
    //    collectibles themselves resolve via their own buildingGrid field)
    //
    // Recurses into ByteArrays: Flex servers often nest the real VO inside a
    // ByteArray field of AcknowledgeMessage. We re-parse the ByteArray bytes
    // as a fresh AMF3 value and continue the search there.
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
            // dResourceVO.name_string is the canonical trade-side resource
            // identifier ("Tool", "Wood", "Salpeter", "EMEventResource"…).
            // Collect every one so the trade panel's dropdowns can populate
            // from wire-confirmed names rather than a hardcoded guess list.
            if (shortCls === 'dResourceVO' && typeof v.name_string === 'string' && v.name_string) {
                ctx.resourceNames[v.name_string] = true;
            }
            // dTradeObjectVO carries an `offer` string of the form
            //   "<offerResource>,<amount>|<costResource-or-action>,<amount>[,<extra>]|<lots>"
            // The LHS pipe-segment is always a resource (it's what's given);
            // the middle segment can be a resource OR an action verb
            // (FillDeposit, BuildBuilding). We only harvest the LHS — safe
            // and unambiguous.
            if (shortCls === 'dTradeObjectVO' && typeof v.offer === 'string') {
                var seg = v.offer.split('|')[0];
                if (seg) {
                    var nm = seg.split(',')[0];
                    if (nm) ctx.resourceNames[nm] = true;
                }
            }
            // dServerActionResult.clientTime is the server-clock double, returned
            // in every response envelope. Snapshot the latest into ctx for the
            // SPECIALISTS payload; used as the reference for collectedTime conversion.
            if (shortCls === 'dServerActionResult' && typeof v.clientTime === 'number') {
                ctx.serverClock = v.clientTime;
            }
            // dPlayerVO: capture player level and collect full VO for buff inventory extraction.
            if (shortCls === 'dPlayerVO') {
                if (typeof v.playerLevel === 'number') ctx.playerLevel = v.playerLevel;
                // Snapshot identifying fields off every dPlayerVO encountered
                // — we don't yet know which one is the local-player VO on
                // adventure / visit responses, so log them all and decide.
                ctx.playerVOSamples.push({
                    userID:         (typeof v.userID === 'number')        ? v.userID        : null,
                    zoneID:         (typeof v.zoneID === 'number')        ? v.zoneID        : null,
                    landingZoneID:  (typeof v.landingZoneID === 'number') ? v.landingZoneID : null,
                    playerLevel:    (typeof v.playerLevel === 'number')   ? v.playerLevel   : null,
                    hasInventory:   Array.isArray((v.availableBuffs_vector || {}).source)
                                    && v.availableBuffs_vector.source.length > 0,
                });
                ctx.playerVOs.push(v);
            }
            // dZoneVO ownership + identity — independent signal that doesn't
            // depend on guessing which dPlayerVO is "ours".
            if (shortCls === 'dZoneVO') {
                if (typeof v.zoneOwnerPlayerID   === 'number') ctx.zoneOwnerPlayerID   = v.zoneOwnerPlayerID;
                if (typeof v.zoneVisitorPlayerID === 'number') ctx.zoneVisitorPlayerID = v.zoneVisitorPlayerID;
                if (typeof v.gameWorldName === 'string') ctx.gameWorldName = v.gameWorldName;
                if (typeof v.adventureName === 'string') ctx.adventureName = v.adventureName;
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
        // package paths; require both fields to be positive numbers. Also
        // collect the VO itself so the PFB scanner can walk its keys.
        if (typeof v.mapWidth  === 'number' && v.mapWidth  > 0 &&
            typeof v.mapHeight === 'number' && v.mapHeight > 0) {
            ctx.maps.push({ w: v.mapWidth, h: v.mapHeight, cls: v.__class || '?' });
            ctx.zoneVOs.push(v);
        }

        // Tree-wide PFB hit: any VO whose buffName_string names the
        // Prestigious Friend Buff. Captured so we can log the parent
        // class and field structure for AMF reverse-engineering.
        if (v.__class &&
            typeof v.buffName_string === 'string' &&
            isPfbBuffName(v.buffName_string)) {
            ctx.treePfbHits.push({
                cls: v.__class,
                name: v.buffName_string,
                parentCls: (parent && parent.__class) ? parent.__class : '<root>',
                keys: Object.keys(v).filter(function(k) { return k !== '__class'; }).join(','),
                insertedAt: v.insertedAt,
                endTime: v.endTime,
            });
        }

        var nextParent = meaningfulParent(v) ? v : parent;

        if (v.source !== undefined) scanTree(v.source, depth + 1, ctx, nextParent);

        var keys = Object.keys(v);
        for (var k = 0; k < keys.length; k++) {
            var key = keys[k];
            if (key === '__class' || key === 'source') continue;
            // Skip subtrees no consumer walks. armyVO (unit composition, deep
            // per specialist), skills / eventSkills (SkillVO arrays we harvest
            // directly at the dSpecialistVO push, not via the tree walk),
            // battlesFought/unitsProduced (large stat arrays on Generals).
            // These skips cap the ctx.seen WeakSet size and Object.keys churn
            // during the walk.
            if (SCAN_SKIP_KEYS[key]) continue;
            scanTree(v[key], depth + 1, ctx, nextParent);
        }
    }

    var SCAN_SKIP_KEYS = {
        armyVO:       1,
        skills:       1,
        eventSkills:  1,
    };

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
            zoneVOs:      [],    // dZoneVO instances (PFB / zone-buff candidates)
            serverClock:  null,  // dServerActionResult.clientTime (most recent in this response)
            playerLevel:  null,  // dPlayerVO.playerLevel (set on zone-load responses)
            playerVOSamples: [], // {userID, zoneID, landingZoneID, playerLevel, hasInventory} per dPlayerVO
            zoneOwnerPlayerID:   null,
            zoneVisitorPlayerID: null,
            gameWorldName: null,
            adventureName: null,
            treePfbHits:  [],    // VOs in the tree whose buffName_string names PFB
            resourceNames: {},   // { name_string: true } — set of wire-confirmed
                                 // resource names harvested this response
        };
    }

    // ── PFB (Prestigious Friend Buff) auto-detection ─────────────────────
    // Internal asset family: MultiplierBuffZone2_PremiumFriendBuff*.
    // The active-buff vector field name isn't known yet — we scan every
    // candidate key on dPlayerVO + dZoneVO that holds a vector of objects
    // with buffName_string, and any whose name matches counts as active
    // (excluding the player's inventory at availableBuffs_vector).

    function isPfbBuffName(name) {
        if (typeof name !== 'string') return false;
        // PremiumFriendBuff catches every variant (1Day/7Day/15Day). The
        // broader "MultiplierBuffZone" match was dropped — it false-positives
        // on MultiplierBuffZone1 and the Premium Compensation Buff, which
        // are *not* PFB.
        return name.indexOf('PremiumFriendBuff') >= 0;
    }

    // Known buff-definition IDs that mean "active Prestigious Friend Buff".
    // dPersistedBuffApplianceVO.buffID is a numeric reference to the buff
    // definition; the appliance never carries the name string. Confirmed on
    // 2026-06-14: buffID 663 = MultiplierBuffZone2_PremiumFriendBuff15Day
    // on realm r03 (user's friend applied the 15-day variant; inventory
    // also contained an unrelated 1Day token). 1Day and 7Day variant IDs
    // are unconfirmed — capture them from a fresh [PFB:appliance.all]
    // dump when those are seen and add them here.
    var PFB_BUFF_IDS = { 663: '15Day' };

    function scanForPlayerBuffs(ctx) {
        var pfbActive    = false;
        var vectorsSeen  = 0;
        var pfbHits      = 0;
        var pfbFromField = null;   // first field where we found a hit (debug)

        function scanRoot(root, rootCls) {
            if (!root) return;
            var keys = Object.keys(root);
            for (var i = 0; i < keys.length; i++) {
                var key = keys[i];
                if (key === '__class') continue;
                var v = root[key];
                if (v == null) continue;
                var list = unwrapCollection(v);
                if (list.length === 0) continue;
                var first = list[0];
                if (!first || typeof first !== 'object') continue;
                if (typeof first.buffName_string !== 'string') continue;

                vectorsSeen++;
                var hits = 0;
                var sampleHit = null;
                for (var li = 0; li < list.length; li++) {
                    var b = list[li];
                    if (b && isPfbBuffName(b.buffName_string)) {
                        hits++;
                        if (!sampleHit) sampleHit = b;
                    }
                }
                pfbHits += hits;

                // availableBuffs_vector is the inventory of buffs the player
                // owns — a PFB token there isn't "active", it's stocked. Any
                // OTHER vector with a PFB-named entry counts as active.
                var isInventory = (key === 'availableBuffs_vector');
                if (hits > 0 && !isInventory) {
                    pfbActive = true;
                    if (!pfbFromField) pfbFromField = rootCls + '.' + key;
                }
            }
        }

        for (var pi = 0; pi < ctx.playerVOs.length; pi++) scanRoot(ctx.playerVOs[pi], 'dPlayerVO');
        for (var zi = 0; zi < ctx.zoneVOs.length;   zi++) scanRoot(ctx.zoneVOs[zi],   'dZoneVO');

        // BuffAppliance walk: dZoneVO.zoneBuffs is a Vector of
        // dPersistedBuffApplianceVO representing currently-active zone-wide
        // buffs (incl. PFB). The appliance references its buff definition
        // by numeric `buffID` only — it never carries the name string —
        // so detection is an ID lookup against PFB_BUFF_IDS.
        var applianceCount = 0;
        var pfbAppliances  = 0;
        var seenBuffIDs    = [];   // diagnostic: all buffIDs seen this payload
        function scanApplianceVectors(root, rootCls) {
            if (!root) return;
            var keys = Object.keys(root);
            for (var i = 0; i < keys.length; i++) {
                var k = keys[i];
                if (k === '__class') continue;
                var list = unwrapCollection(root[k]);
                if (list.length === 0) continue;
                var first = list[0];
                if (!first || typeof first !== 'object' || !first.__class) continue;
                if (first.__class.indexOf('BuffAppliance') < 0) continue;

                for (var li = 0; li < list.length; li++) {
                    var appl = list[li];
                    if (!appl || typeof appl !== 'object') continue;
                    applianceCount++;
                    var id = (typeof appl.buffID === 'number') ? appl.buffID : null;
                    if (id != null) seenBuffIDs.push(id);
                    if (id != null && PFB_BUFF_IDS.hasOwnProperty(id)) {
                        pfbAppliances++;
                        pfbActive = true;
                        if (!pfbFromField) pfbFromField = rootCls + '.' + k;
                        window._tsoDiagLog(
                            '[PFB:appliance.hit] ' + rootCls + '.' + k +
                            '[' + li + '] buffID=' + id +
                            ' variant=' + PFB_BUFF_IDS[id] +
                            ' startTime=' + appl.startTime +
                            ' applianceMode=' + appl.applianceMode
                        );
                    }
                }
            }
        }
        for (var pi2 = 0; pi2 < ctx.playerVOs.length; pi2++) scanApplianceVectors(ctx.playerVOs[pi2], 'dPlayerVO');
        for (var zi2 = 0; zi2 < ctx.zoneVOs.length;   zi2++) scanApplianceVectors(ctx.zoneVOs[zi2],   'dZoneVO');

        return {
            pfbActive:       pfbActive,
            vectorsSeen:     vectorsSeen,
            pfbHits:         pfbHits,
            fromField:       pfbFromField,
            appliancesSeen:  applianceCount,
            pfbAppliances:   pfbAppliances,
            seenBuffIDs:     seenBuffIDs,
        };
    }

    // ── Collectibles output assembler ─────────────────────────────────────

    var _cachedMapWidth  = 0, _cachedMapHeight = 0;  // retained across pickup responses
    var _prevCollectibles = null;  // null until first zone-load; {gridIndex→item} thereafter
    var _lastZoneKey = undefined;  // (zoneOwnerPlayerID, zoneVisitorPlayerID) tuple — transition key

    // ── Home-zone gate ──────────────────────────────────────────────────
    // Features (panel updates, auto-loop) only run on the local player's
    // own non-adventure zone. The signal we trust is dZoneVO.{zoneOwner,
    // zoneVisitor}PlayerID: home ⇔ owner == visitor && no adventureName.
    // We do NOT gate on the auth-ctx zoneID — when the game issues a
    // "visit friend" outbound, that request carries the home zoneID, so
    // auth-ctx still reads home when the friend-zone inbound lands and
    // the gate would falsely admit friend data.
    //
    // Sticky across payloads: incremental updates between zone-loads
    // don't carry dZoneVO, so we reuse the last observed on-home state.
    // Default true so the first home zone-load (which sets the bool
    // explicitly) isn't preceded by a dropped no-zone payload.
    var _isOnHome = true;

    function isOnHome(ctx) {
        if (ctx.zoneOwnerPlayerID !== null && ctx.zoneVisitorPlayerID !== null) {
            _isOnHome = (ctx.zoneOwnerPlayerID === ctx.zoneVisitorPlayerID) &&
                        !ctx.adventureName;
        }
        return _isOnHome;
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

    // ── analyzeAMFBuffer ──────────────────────────────────────────────────
    // Called by the net interceptor for both fetch and XHR responses. Parses
    // an envelope, walks it, then runs each extractor.
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

                        // Diag-only recon: pretty-stringifying every ack was
                        // ~tens of KB of allocation per response (guild rosters
                        // and trade windows are large). Gate the full block on
                        // _tsoDiag so shipped features pay nothing. The typed
                        // extractors below (1014/1062/4014) still run.
                        if (window._tsoDiag) {
                            var srJson = '';
                            try { srJson = JSON.stringify(sr); } catch (_) {}
                            window._tsoDiagLog(
                                '[AMF3:' + channel + '] ack type=' + sr.type +
                                ' errorCode=' + (sr.data && sr.data.errorCode) +
                                ' full=' + srJson.slice(0, 1500));

                            var tag = srJson.indexOf('TradeWindow')              >= 0 ||
                                      srJson.indexOf('DirectTrade')              >= 0 ||
                                      srJson.indexOf('Mail')                     >= 0 ||
                                      srJson.indexOf('Gift')                     >= 0 ||
                                      srJson.indexOf('Donat')                    >= 0 ||
                                      srJson.indexOf('SendResources')            >= 0 ||
                                      srJson.indexOf('Player2Player')            >= 0 ||
                                      srJson.indexOf('PlayerToPlayer')           >= 0 ? 'Trade'
                                    : srJson.indexOf('Guild.dGuildVO')           >= 0 ||
                                      srJson.indexOf('dGuildPlayerListItemVO')   >= 0 ? 'Guild'
                                    : srJson.indexOf('dPlayerListVO')            >= 0 ||
                                      srJson.indexOf('dPlayerListItemVO')        >= 0 ? 'Friends'
                                    : null;
                            if (tag) {
                                webkit.messageHandlers.logger.postMessage(
                                    '[' + tag + ':in:' + channel + '] type=' + sr.type +
                                    ' errorCode=' + (sr.data && sr.data.errorCode) +
                                    ' bytes=' + srJson.length +
                                    ' full=' + srJson.slice(0, 16000)
                                );
                            }
                        }

                        // FRIENDS: dServerResponse type=1014 carries dPlayerListVO
                        // → ArrayCollection<dPlayerListItemVO>{ id, avatarId,
                        // username, playerLevel, friendSince, onlineStatus }.
                        if (sr.type === 1014) {
                            var fInner = sr.data && sr.data.data;
                            var fList  = unwrapCollection(fInner && fInner.players != null ? fInner.players : fInner);
                            var fItems = [];
                            for (var fi = 0; fi < fList.length; fi++) {
                                var fp = fList[fi];
                                if (!fp || !fp.__class || fp.__class.indexOf('dPlayerListItemVO') < 0) continue;
                                fItems.push({
                                    id:       (typeof fp.id === 'number') ? fp.id : 0,
                                    username: (typeof fp.username === 'string') ? fp.username : '',
                                    level:    (typeof fp.playerLevel === 'number') ? fp.playerLevel : 0,
                                    online:   !!fp.onlineStatus,
                                });
                            }
                            if (fItems.length > 0) {
                                window._tsoSend('FRIENDS', { items: fItems });
                                webkit.messageHandlers.logger.postMessage(
                                    '[Friends:emit] count=' + fItems.length);
                            }
                        }

                        // GUILD_MEMBERS: dServerResponse type=4014 carries
                        // dGuildVO; the member-list field name on that VO
                        // isn't catalogued yet, so walk every key looking for
                        // a collection whose first item is dGuildPlayerListItemVO.
                        if (sr.type === 4014) {
                            var guild = sr.data && sr.data.data;
                            if (guild && typeof guild === 'object') {
                                var gKeys = Object.keys(guild);
                                var gMembers = null;
                                var gFieldName = null;
                                for (var gki = 0; gki < gKeys.length; gki++) {
                                    var gK = gKeys[gki];
                                    if (gK === '__class' || gK === 'leader') continue;
                                    var gv = guild[gK];
                                    if (gv == null) continue;
                                    var glist = unwrapCollection(gv);
                                    if (glist.length === 0) continue;
                                    var gfirst = glist[0];
                                    if (gfirst && gfirst.__class &&
                                        gfirst.__class.indexOf('dGuildPlayerListItemVO') >= 0) {
                                        gMembers = glist;
                                        gFieldName = gK;
                                        break;
                                    }
                                }
                                if (gMembers && gMembers.length > 0) {
                                    // One-time field-key dump so we can refine
                                    // the extractor with confirmed key names.
                                    if (!window._tsoGuildKeysDumped) {
                                        window._tsoGuildKeysDumped = true;
                                        var gSample = gMembers[0];
                                        var gSampleJson = '';
                                        try { gSampleJson = JSON.stringify(gSample).slice(0, 1500); } catch (_) {}
                                        webkit.messageHandlers.logger.postMessage(
                                            '[GuildMembers:keys] field=' + gFieldName +
                                            ' count=' + gMembers.length +
                                            ' keys=' + Object.keys(gSample).filter(function(k){return k!=='__class';}).join(',') +
                                            ' sample=' + gSampleJson);
                                    }
                                    var gItems = [];
                                    for (var mi = 0; mi < gMembers.length; mi++) {
                                        var gm = gMembers[mi];
                                        if (!gm) continue;
                                        // Try several plausible field names. Once
                                        // we see the keys dump above we'll narrow.
                                        var gid = (typeof gm.playerID === 'number') ? gm.playerID
                                                : (typeof gm.userID   === 'number') ? gm.userID
                                                : (typeof gm.id       === 'number') ? gm.id
                                                : 0;
                                        var gname = (typeof gm.username        === 'string') ? gm.username
                                                  : (typeof gm.username_string === 'string') ? gm.username_string
                                                  : (typeof gm.name            === 'string') ? gm.name
                                                  : (typeof gm.name_string     === 'string') ? gm.name_string
                                                  : '';
                                        var glevel = (typeof gm.playerLevel === 'number') ? gm.playerLevel : 0;
                                        gItems.push({
                                            id:       gid,
                                            username: gname,
                                            level:    glevel,
                                            online:   !!gm.onlineLast24 || !!gm.onlineStatus,
                                        });
                                    }
                                    window._tsoSend('GUILD_MEMBERS', { items: gItems });
                                    webkit.messageHandlers.logger.postMessage(
                                        '[GuildMembers:emit] count=' + gItems.length);
                                }
                            }
                        }
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

        // Resource-name accumulator — runs on every parsed response,
        // regardless of home-zone gating. Trade-office responses contain
        // tons of dResourceVO instances and offer strings; the panel's
        // dropdowns grow as the player navigates the game.
        //
        // _tsoSeenResources persists for the session; Swift side persists
        // to UserDefaults so the list grows across launches. We only emit
        // when the set actually grew to avoid bridge spam.
        if (!window._tsoSeenResources) window._tsoSeenResources = {};
        var seen = window._tsoSeenResources;
        var added = 0;
        for (var rname in ctx.resourceNames) {
            if (!seen[rname]) { seen[rname] = true; added++; }
        }
        if (added > 0) {
            var names = Object.keys(seen).sort();
            window._tsoSend('RESOURCES', { names: names });
            webkit.messageHandlers.logger.postMessage(
                '[Resources:emit] +' + added + ' new (' + names.length + ' total)');
        }

        // Skip responses that carry no game-world data at all.
        // Settings/auth have none of these; destruct-only pickup responses have ctx.destructed.
        if (ctx.items.length === 0 && ctx.maps.length === 0 &&
            ctx.allBuildings.length === 0 && ctx.destructed.length === 0) return;

        // ── Home-zone diagnostic + gate ─────────────────────────────────────
        // Log on every (owner, visitor) transition so we can see home→visit
        // →adventure moves in the console. Done up here so the line still
        // appears when we're off-home and the rest of the pipeline is skipped.
        if (ctx.zoneOwnerPlayerID !== null || ctx.zoneVisitorPlayerID !== null) {
            var key = ctx.zoneOwnerPlayerID + ':' + ctx.zoneVisitorPlayerID;
            if (key !== _lastZoneKey) {
                _lastZoneKey = key;
                var samples = ctx.playerVOSamples.map(function(s) {
                    return 'user=' + s.userID +
                           ' zone=' + s.zoneID +
                           ' land=' + s.landingZoneID +
                           ' lvl=' + s.playerLevel +
                           ' inv=' + s.hasInventory;
                }).join(' | ');
                webkit.messageHandlers.logger.postMessage(
                    '[HomeZone] owner=' + ctx.zoneOwnerPlayerID +
                    ' visitor=' + ctx.zoneVisitorPlayerID +
                    ' world=' + ctx.gameWorldName +
                    ' adv=' + ctx.adventureName +
                    ' playerVOs=' + ctx.playerVOSamples.length +
                    (samples ? ' [' + samples + ']' : '')
                );
            }
        }

        var onHome = isOnHome(ctx);
        window._tsoOnHome = onHome;
        if (!onHome) return;  // freeze panel + suppress auto-loop while away

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

        // Persist captured clock/player level even if no specialists in this response.
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
                var taskTypeHint = classifier.classifyFromTask(taskObj);
                if (taskTypeHint) {
                    if (!window._tsoSpecTypeHints) window._tsoSpecTypeHints = {};
                    window._tsoSpecTypeHints[uk] = taskTypeHint;
                }
                var hints = window._tsoSpecTypeHints;
                var subTypeId = (typeof sp.specialistType === 'number') ? sp.specialistType : -1;
                var spType = (hints && hints[uk])
                    || taskTypeHint
                    || classifier.classifySpec(subTypeId, sp.garrisonBuildingGridPos | 0, sp.name_string);

                // Skills: ArrayCollection of SkillVO{id, level}. Emit {id,level} pairs
                // where level > 0. Level is needed for ExplorerDurationRegistry estimates;
                // older callers that only need IDs read .id off each entry.
                var skills = [];
                unwrapCollection(sp.skills).forEach(function(sk) {
                    if (sk && typeof sk.id === 'number' && (sk.level | 0) > 0) {
                        skills.push({ id: sk.id, level: sk.level | 0 });
                    }
                });

                var collectedTime = (taskObj && typeof taskObj.collectedTime === 'number')
                    ? taskObj.collectedTime : null;
                var bonusTime = (taskObj && typeof taskObj.bonusTime === 'number')
                    ? taskObj.bonusTime : null;

                if (taskObj !== null) {
                    var _label = classifier.subtypeNameFor(subTypeId) || spType;
                    if (sp.name_string) _label = sp.name_string + ' (' + _label + ')';
                    var _taskFields = Object.keys(taskObj).filter(function(k) { return k !== '__class'; }).map(function(k) {
                        var v = taskObj[k];
                        if (v instanceof Date) return k + '=Date(' + v.getTime() + ')';
                        if (v === null || v === undefined) return k + '=null';
                        if (typeof v === 'object') return k + '={' + Object.keys(v).slice(0,6).join(',') + '}';
                        return k + '=' + v;
                    }).join(' ');
                    window._tsoDiagLog(
                        '[AMF3:spec:timing] ' + _label + ' uid=' + uk +
                        ' serverClock=' + ctx.serverClock + ' | ' + _taskFields);
                }

                specItems.push({
                    uid: uk,
                    uid1: u1,
                    uid2: u2,
                    specialistType: spType,
                    subTypeId: subTypeId,
                    subTypeName: classifier.subtypeNameFor(subTypeId),
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
                window._tsoDiagLog(
                    '[AMF3:' + channel + '] specialists=' + specItems.length +
                    ' level=' + (window._tsoPlayerLevel != null ? window._tsoPlayerLevel : '?'));
                // Diagnostic: surface premium variants whose numeric specialistType isn't
                // in EXPLORER_TYPES/GEOLOGIST_TYPES/GENERAL_TYPES so they can be added.
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
                    window._tsoDiagLog(
                        '[AMF3:bldg:exemplar] skin=' + bSkin + ' | ' + bFields);
                    loggedExemplar = true;
                }
                // Extract a "currently buffed" marker for this building. The
                // entry is a dBuffApplianceVO which carries only a numeric
                // `buffID` — there is no name string on the appliance itself.
                // We need a non-null sentinel so the Swift skip-if-buffed
                // filter (BuffDispatchCoordinator) fires; prefer name when
                // present, fall back to buffID, then a generic marker.
                var activeBuff = null;
                var bBuffList = unwrapCollection(b.buffs);
                for (var bbi = 0; bbi < bBuffList.length; bbi++) {
                    var bf0 = bBuffList[bbi];
                    if (!bf0) continue;
                    if (typeof bf0.buffName_string === 'string' && bf0.buffName_string.length > 0) {
                        activeBuff = bf0.buffName_string;
                    } else if (typeof bf0.buffID === 'number') {
                        activeBuff = 'buffID:' + bf0.buffID;
                    } else {
                        activeBuff = '<active>';
                    }
                    break;
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
                for (var si2 = 0; si2 < buildingItems.length; si2++) {
                    var base = buildingItems[si2].skin.replace(/_\d+$/, '');
                    skinCounts[base] = (skinCounts[base] || 0) + 1;
                }
                var skinSummary = Object.keys(skinCounts).sort().map(function(k) {
                    return k + ' x' + skinCounts[k];
                }).join('\n  ');
                window._tsoDiagLog(
                    '[AMF3:buildings] total=' + buildingItems.length + '\n  ' + skinSummary);
            }
        }

        // ── Buff inventory extraction ─────────────────────────────────────────
        // availableBuffs_vector lives on dPlayerVO. Emit BUFFS bridge message and
        // log a sample whenever the inventory is non-empty.
        for (var pi = 0; pi < ctx.playerVOs.length; pi++) {
            var pvo = ctx.playerVOs[pi];
            var buffList = unwrapCollection(pvo.availableBuffs_vector);
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
                var buffCounts = {};
                for (var bci = 0; bci < buffItems.length; bci++) {
                    var bn = buffItems[bci].buffName || '(unknown)';
                    buffCounts[bn] = (buffCounts[bn] || 0) + 1;
                }
                var buffSummary = Object.keys(buffCounts).sort().map(function(k) {
                    return k + ' x' + buffCounts[k];
                }).join(', ');
                window._tsoDiagLog(
                    '[AMF3:buffs] total=' + buffItems.length + ' | ' + buffSummary);
            }
        }

        // ── PFB scan + bridge emission ──────────────────────────────────────
        // Runs on every payload that has any player/zone data. Logs a one-line
        // summary so the user can confirm detection ran; emits PLAYER_BUFFS
        // back to Swift so SpecialistsStore.pfbActive can auto-track. Also
        // dumps any tree-wide PFB-named VOs (deduped by class/name) so we can
        // reverse-engineer the active-buff field once we see live data.
        if (ctx.playerVOs.length > 0 || ctx.zoneVOs.length > 0) {
            var scan = scanForPlayerBuffs(ctx);
            for (var ti = 0; ti < ctx.treePfbHits.length && ti < 5; ti++) {
                var h = ctx.treePfbHits[ti];
                window._tsoDiagLog(
                    '[PFB:tree] cls=' + h.cls +
                    ' name=' + h.name +
                    ' parent=' + h.parentCls +
                    ' keys=' + h.keys +
                    ' insertedAt=' + h.insertedAt +
                    ' endTime=' + h.endTime
                );
            }
            window._tsoDiagLog(
                '[PFB:summary] active=' + scan.pfbActive +
                ' vectorsScanned=' + scan.vectorsSeen +
                ' hitsInVectors=' + scan.pfbHits +
                ' hitsInTree=' + ctx.treePfbHits.length +
                ' appliances=' + scan.appliancesSeen +
                ' pfbAppliances=' + scan.pfbAppliances +
                ' buffIDs=[' + scan.seenBuffIDs.join(',') + ']' +
                (scan.fromField ? ' field=' + scan.fromField : '')
            );
            window._tsoSend('PLAYER_BUFFS', { pfbActive: scan.pfbActive });
        }

        // Track current collectible set so DestructBuildingResultVO can remove the right entry.
        var currentSet = {};
        result.items.forEach(function(it) { currentSet[it.gridIndex] = it; });
        _prevCollectibles = currentSet;
    }

    window._tsoScanner = {
        analyzeAMFBuffer: analyzeAMFBuffer,
    };
})();
