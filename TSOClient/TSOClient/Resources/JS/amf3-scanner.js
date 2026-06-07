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

    // ── Collectibles output assembler ─────────────────────────────────────

    var _cachedMapWidth  = 0, _cachedMapHeight = 0;  // retained across pickup responses
    var _prevCollectibles = null;  // null until first zone-load; {gridIndex→item} thereafter

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

                // Skills: ArrayCollection of SkillVO{id, level}. Emit IDs where level > 0.
                var skills = [];
                unwrapCollection(sp.skills).forEach(function(sk) {
                    if (sk && typeof sk.id === 'number' && (sk.level | 0) > 0) skills.push(sk.id);
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
                webkit.messageHandlers.logger.postMessage(
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
                    webkit.messageHandlers.logger.postMessage(
                        '[AMF3:bldg:exemplar] skin=' + bSkin + ' | ' + bFields);
                    loggedExemplar = true;
                }
                // Extract the first currently-applied buff name on this building.
                var activeBuff = null;
                var bBuffList = unwrapCollection(b.buffs);
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
                for (var si2 = 0; si2 < buildingItems.length; si2++) {
                    var base = buildingItems[si2].skin.replace(/_\d+$/, '');
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
                webkit.messageHandlers.logger.postMessage(
                    '[AMF3:buffs] total=' + buffItems.length + ' | ' + buffSummary);
            }
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
