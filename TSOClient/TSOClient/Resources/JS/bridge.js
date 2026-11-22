(function() {
    'use strict';

    // Shared timestamp helper for JS-side logs (mirrors Swift's LogTimestamp).
    window._tsoTs = function() {
        var d = new Date();
        var pad = function(n, w) { var s = String(n); while (s.length < w) s = '0' + s; return s; };
        return '[' + pad(d.getHours(), 2) + ':' + pad(d.getMinutes(), 2) + ':' +
               pad(d.getSeconds(), 2) + '.' + pad(d.getMilliseconds(), 3) + ']';
    };

    // JS → Swift: send a typed message.
    window._tsoSend = function(type, payload) {
        try {
            webkit.messageHandlers.tso.postMessage({ type: type, payload: payload ?? null });
        } catch(e) {
            console.warn(window._tsoTs(), '[TSOBridge] send failed:', e);
        }
    };

    // Diagnostic logger — gated by _tsoDiag so per-response AMF dumps don't
    // hammer the Swift logger bridge during long sessions. Each call is a
    // bridge IPC + main-thread hop + os_log write; over hours of play that
    // dominates CPU when verbose logs are on. Toggle from Safari Web Inspector:
    //   window._tsoDiag = true
    window._tsoDiag = false;
    window._tsoDiagLog = function(msg) {
        if (!window._tsoDiag) return;
        try { webkit.messageHandlers.logger.postMessage(msg); } catch(_) {}
    };

    // Introspection helpers for the per-building VO snapshot populated by
    // amf3-scanner.js on every full zone-load. Unlike `_tsoDiagLog`, these log
    // unconditionally — they're meant to be called by hand from Safari Web
    // Inspector (or by Swift via evaluateJavaScript) during field discovery,
    // and the user wants the output in the file sink regardless of `_tsoDiag`.
    //
    // Example workflow for finding the "production paused" field:
    //   1. window._tsoDumpBuilding(1234)              // active sample
    //   2. [pause the building in-game, trigger a zone reload]
    //   3. window._tsoDumpBuilding(1234)              // paused sample — diff lines
    //   4. window._tsoDiffBuildings(1234, 5678)       // or compare to another
    function _tsoBldgLog(msg) {
        try { webkit.messageHandlers.logger.postMessage(msg); } catch(_) {}
    }
    window._tsoDumpBuilding = function(grid) {
        var map = window._tsoLastBuildingsByGrid || {};
        var b = map[grid];
        if (!b) {
            _tsoBldgLog('[BldgDump] no building at grid ' + grid +
                        ' (last scan empty? trigger a zone reload first)');
            return;
        }
        var lines = Object.keys(b).sort().map(function(k) {
            return '  ' + k + '=' + b[k];
        });
        _tsoBldgLog('[BldgDump] grid=' + grid + '\n' + lines.join('\n'));
    };
    // Pause a building in-game → zone-reload → call
    //   window._tsoScanBuildings("WoodCutter")
    // Walks every snapshotted building whose skin contains `skinSubstring`
    // (case-insensitive) and logs the fields that *don't* have a uniform
    // value across the group. The pause flag is a boolean that splits the
    // set N-1 vs 1; that's the "smoking gun" value distribution.
    window._tsoScanBuildings = function(skinSubstring) {
        var map = window._tsoLastBuildingsByGrid || {};
        var needle = (skinSubstring || '').toLowerCase();
        var grids = Object.keys(map).filter(function(g) {
            var sk = map[g].skin;
            return typeof sk === 'string' && sk.toLowerCase().indexOf(needle) >= 0;
        });
        if (grids.length < 2) {
            _tsoBldgLog('[BldgScan] need >=2 matching buildings, got ' +
                        grids.length + ' for "' + skinSubstring + '"');
            return;
        }
        var allKeys = {};
        grids.forEach(function(g) {
            Object.keys(map[g]).forEach(function(k) { allKeys[k] = true; });
        });
        var lines = [];
        Object.keys(allKeys).sort().forEach(function(k) {
            var byVal = {};
            grids.forEach(function(g) {
                var v = String(map[g][k]);
                byVal[v] = (byVal[v] || 0) + 1;
            });
            var distinct = Object.keys(byVal);
            if (distinct.length === 1) return;   // uniform — irrelevant
            // Cap display at 4 distinct values so widely-unique fields (grid,
            // uid, position) don't dominate the output.
            var pairs;
            if (distinct.length <= 4) {
                pairs = distinct.map(function(v) { return v + 'x' + byVal[v]; });
            } else {
                pairs = ['(' + distinct.length + ' unique)'];
            }
            lines.push('  ' + k + ' : ' + pairs.join(' | '));
        });
        _tsoBldgLog('[BldgScan] skin~"' + skinSubstring + '" N=' + grids.length +
                    ' fields that vary:\n' + lines.join('\n'));
    };
    // Appliance (dBuffApplianceVO) introspection — same shape as _tsoDump*,
    // but keyed off `_tsoLastAppliancesByGrid`. Use to discover timing
    // fields (insertedAt / expiry / duration) on a buffed building.
    window._tsoDumpAppliance = function(grid) {
        var map = window._tsoLastAppliancesByGrid || {};
        var a = map[grid];
        if (!a) {
            _tsoBldgLog('[ApplianceDump] no appliance at grid ' + grid +
                        ' (building unbuffed, or last scan empty)');
            return;
        }
        var lines = Object.keys(a).sort().map(function(k) {
            return '  ' + k + '=' + a[k];
        });
        _tsoBldgLog('[ApplianceDump] grid=' + grid + '\n' + lines.join('\n'));
    };
    // Scan every buffed building. Groups by buffID so each distinct active
    // buff is reported separately (durations differ per buff type). For each
    // group, logs per-field value distribution — fields where two appliances
    // of the same buffID have different values are likely timing-related.
    window._tsoScanAppliances = function() {
        var map = window._tsoLastAppliancesByGrid || {};
        var grids = Object.keys(map);
        if (grids.length === 0) {
            _tsoBldgLog('[ApplianceScan] no buffed buildings in last scan');
            return;
        }
        var byBuffID = {};
        grids.forEach(function(g) {
            var id = map[g].buffID != null ? String(map[g].buffID) : '?';
            (byBuffID[id] = byBuffID[id] || []).push(g);
        });
        Object.keys(byBuffID).sort().forEach(function(id) {
            var gs = byBuffID[id];
            var allKeys = {};
            gs.forEach(function(g) {
                Object.keys(map[g]).forEach(function(k) { allKeys[k] = true; });
            });
            var lines = [];
            Object.keys(allKeys).sort().forEach(function(k) {
                var byVal = {};
                gs.forEach(function(g) {
                    var v = String(map[g][k]);
                    byVal[v] = (byVal[v] || 0) + 1;
                });
                var distinct = Object.keys(byVal);
                var pairs = distinct.length <= 4
                    ? distinct.map(function(v) { return v + 'x' + byVal[v]; })
                    : ['(' + distinct.length + ' unique)'];
                var tag = distinct.length === 1 ? '   uniform' : '  varies';
                lines.push(tag + '  ' + k + ' : ' + pairs.join(' | '));
            });
            _tsoBldgLog('[ApplianceScan] buffID=' + id + ' N=' + gs.length +
                        '\n' + lines.join('\n'));
        });
    };
    // Class inventory from the last full zone-load response. Pass a substring
    // to filter (case-insensitive); defaults to listing every class seen.
    // Use to find undiscovered VO shapes:
    //   _tsoClassScan("Buff")   → every class whose name contains "Buff"
    //   _tsoClassScan("Def")    → candidates for a buff-definition VO
    //   _tsoClassScan()         → full catalog (~hundreds of classes)
    window._tsoClassScan = function(substring) {
        var counts = window._tsoLastClassCounts || {};
        var keys = Object.keys(counts);
        var needle = (substring || '').toLowerCase();
        if (needle) keys = keys.filter(function(k) { return k.toLowerCase().indexOf(needle) >= 0; });
        if (keys.length === 0) {
            _tsoBldgLog('[ClassScan] no matches for "' + (substring || '') + '" (' +
                        Object.keys(counts).length + ' classes known)');
            return;
        }
        keys.sort();
        var lines = keys.map(function(k) { return '  ' + counts[k] + '  ' + k; });
        _tsoBldgLog('[ClassScan] "' + (substring || '') + '" ' + keys.length +
                    ' hits:\n' + lines.join('\n'));
    };
    // Dump the scalar fields of one exemplar for the given class. Pass either
    // a full class name (defaultGame…dFooVO) or the last segment (dFooVO).
    window._tsoDumpExemplar = function(className) {
        var exemplars = window._tsoLastClassExemplars || {};
        var hit = exemplars[className];
        if (!hit) {
            // Try suffix match on last-segment
            var keys = Object.keys(exemplars);
            var suffix = '.' + className;
            for (var i = 0; i < keys.length; i++) {
                if (keys[i] === className || keys[i].slice(-suffix.length) === suffix) {
                    hit = exemplars[keys[i]]; className = keys[i]; break;
                }
            }
        }
        if (!hit) {
            _tsoBldgLog('[ExemplarDump] no exemplar for ' + className);
            return;
        }
        var keys2 = Object.keys(hit);
        var lines = keys2.sort().map(function(k) {
            var v = hit[k];
            if (v === null || v === undefined) return '  ' + k + '=null';
            if (typeof v === 'object') return '  ' + k + '={cls:' + (v.__class || '?') + '}';
            return '  ' + k + '=' + v;
        });
        _tsoBldgLog('[ExemplarDump] ' + className + '\n' + lines.join('\n'));
    };
    window._tsoDiffBuildings = function(gridA, gridB) {
        var map = window._tsoLastBuildingsByGrid || {};
        var a = map[gridA], b = map[gridB];
        if (!a || !b) {
            _tsoBldgLog('[BldgDiff] missing building(s) a=' + !!a + ' b=' + !!b);
            return;
        }
        var allKeys = {};
        Object.keys(a).forEach(function(k) { allKeys[k] = true; });
        Object.keys(b).forEach(function(k) { allKeys[k] = true; });
        var diffs = [];
        Object.keys(allKeys).sort().forEach(function(k) {
            if (String(a[k]) !== String(b[k])) {
                diffs.push('  ' + k + ': ' + a[k] + ' | ' + b[k]);
            }
        });
        _tsoBldgLog('[BldgDiff] grid ' + gridA + ' | grid ' + gridB +
                    ' (' + diffs.length + ' diffs)' +
                    (diffs.length ? '\n' + diffs.join('\n') : ''));
    };

    // Swift → JS: Swift calls evaluateJavaScript("window.TSOBridge.receive(…)")
    window.TSOBridge = {
        _handlers: {},
        register: function(type, fn) { this._handlers[type] = fn; },
        receive: function(msg) {
            var h = this._handlers[msg.type];
            if (h) { try { h(msg.payload); } catch(e) { console.error(window._tsoTs(), '[TSOBridge]', e); } }
            else { console.log(window._tsoTs(), '[TSOBridge] unhandled type:', msg.type); }
        }
    };
})();
