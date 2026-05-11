import SwiftUI
import WebKit

// MARK: - WebView (NSViewRepresentable)

struct WebView: NSViewRepresentable {
    let url: URL
    var store: CollectiblesStore
    var specialistsStore: SpecialistsStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = config.userContentController

        // Injection order: bridge → scanner → encoder → patcher. The patcher must
        // run after the scanner because it wraps the scanner's already-patched fetch.
        for (source, frame) in [
            (jsBridge,             false),
            (jsAMF3Scanner,        false),
            (jsAMF3Encoder,        false),
            (jsCollectiblePatcher, false),
        ] as [(String, Bool)] {
            controller.addUserScript(
                WKUserScript(source: source,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: frame)
            )
        }

        // "logger" → raw debug strings; "tso" → structured JSON payloads
        controller.add(context.coordinator, name: "logger")
        controller.add(context.coordinator, name: "tso")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate       = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent  =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        webView.isInspectable = true
        context.coordinator.webView = webView
        context.coordinator.registerNotifications()
        NotificationCenter.default.post(name: .tsoWebViewReady, object: webView)
        return webView
    }

    // Only load once — guard prevents reloading on every SwiftUI update.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, specialistsStore: specialistsStore)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

        var store: CollectiblesStore
        var specialistsStore: SpecialistsStore
        weak var webView: WKWebView?

        init(store: CollectiblesStore, specialistsStore: SpecialistsStore) {
            self.store = store
            self.specialistsStore = specialistsStore
        }

        func registerNotifications() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleEvaluateJS(_:)),
                name: .tsoEvaluateJS, object: nil)
        }

        @objc private func handleEvaluateJS(_ note: Notification) {
            guard let js = note.userInfo?["js"] as? String else { return }
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        // Open target="_blank" links inside the same view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation _: WKNavigation!,
                     withError error: Error) {
            print("[TSO] Navigation error: \(error.localizedDescription)")
        }

        // MARK: Bridge dispatch

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "logger" {
                print("[JS] \(message.body)")
                return
            }

            guard let msg = InboundMessage.decode(name: message.name, body: message.body) else {
                print("[TSO] Unknown message from '\(message.name)': \(message.body)")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch msg {
                case .collectibles(let payload):
                    self.store.apply(payload)
                    print("[TSO] Collectibles received: \(payload.items.count) items on \(payload.mapWidth)×\(payload.mapHeight) map")
                case .gameState(let payload):
                    print("[TSO] Game state: \(payload.state) zoneId=\(payload.zoneId.map(String.init) ?? "nil")")
                    if payload.state == "ZONE_LEFT" {
                        self.store.clear()
                        self.specialistsStore.clear()
                    }
                case .specialists(let payload):
                    self.specialistsStore.apply(payload)
                    print("[TSO] Specialists received: \(payload.items.count)")
                }
            }
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @State private var store = CollectiblesStore()
    @State private var specialistsStore = SpecialistsStore()

    var body: some View {
        HSplitView {
            WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!,
                    store: store,
                    specialistsStore: specialistsStore)
                .frame(minWidth: 800, minHeight: 768)

            SpecialistsPanel(store: specialistsStore) { uid1, uid2, subTaskID, targetGrid in
                let js = """
                window._TSORPC?.dispatchSpecialist({
                    uid1:\(uid1),uid2:\(uid2),
                    taskCode:\(subTaskID),targetGrid:\(targetGrid)
                })
                """
                NotificationCenter.default.post(
                    name: .tsoEvaluateJS, object: nil,
                    userInfo: ["js": js])
            }
        }
        .frame(minWidth: 1100, minHeight: 768)
    }
}

extension Notification.Name {
    static let tsoEvaluateJS  = Notification.Name("tsoEvaluateJS")
    static let tsoWebViewReady = Notification.Name("tsoWebViewReady")
}

// MARK: - Injected JavaScript modules
// Each module is a self-contained IIFE registered on window._TSOClient.

// ─────────────────────────────────────────────────────────────────────────────
// 1. Bridge — must be first so other modules can call _tsoSend / TSOBridge.
// ─────────────────────────────────────────────────────────────────────────────
private let jsBridge = #"""
(function() {
    'use strict';

    // JS → Swift: send a typed message.
    window._tsoSend = function(type, payload) {
        try {
            webkit.messageHandlers.tso.postMessage({ type: type, payload: payload ?? null });
        } catch(e) {
            console.warn('[TSOBridge] send failed:', e);
        }
    };

    // Swift → JS: Swift calls evaluateJavaScript("window.TSOBridge.receive(…)")
    window.TSOBridge = {
        _handlers: {},
        register: function(type, fn) { this._handlers[type] = fn; },
        receive: function(msg) {
            var h = this._handlers[msg.type];
            if (h) { try { h(msg.payload); } catch(e) { console.error('[TSOBridge]', e); } }
            else { console.log('[TSOBridge] unhandled type:', msg.type); }
        }
    };
})();
"""#

// ─────────────────────────────────────────────────────────────────────────────
// 3. AMF3 parser — AMF0 envelope + AMF3 deserialiser with full reference tables.
//    findVO recurses into ByteArrays (common Flex pattern: game data nested
//    inside a ByteArray field of AcknowledgeMessage). Falls back to raw-AMF3
//    parse (no envelope) if the envelope tree doesn't yield PickupsDataVO.
//    Emits class-name + hex diagnostics when the tree walk fails.
// ─────────────────────────────────────────────────────────────────────────────
private let jsAMF3Scanner = #"""
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
"""#


// ─────────────────────────────────────────────────────────────────────────────
// 5. Collectible patcher — wraps XMLHttpRequest so that requests for the 55
//    known collectible building textures (identified by their SHA-1 hash in the
//    CDN path /frontend/GFX_HASHED/building_lib/<hash>.png) return a solid pink
//    PNG instead of the real asset.  Unity uploads the substituted bytes to its
//    GL texture and renders the collectible pink — no overlay, no calibration.
//
//    Hash list sourced from perceptron8/pinky.ext (live.json, 55 entries).
//    Must run after jsAMF3Scanner so the Proxy's non-intercept path inherits
//    the scanner's XMLHttpRequest.prototype patches transparently.
// ─────────────────────────────────────────────────────────────────────────────
private let jsCollectiblePatcher = #"""
(function() {
    'use strict';

    var HASHES = new Set([
        '3d22e289f157476f3a79a53c1ce2d16b29064c8a',
        'f9f7e2bacd84c76001820a3621bda5c6959d609d',
        '27b0441fe4a8812665b8af61972966d5294a9ecb',
        '2283394af62449b6d1012dc0c2a8ddfc2cabd34c',
        'c11e14421d3f64ac4cf2f26888deff9f4ad0e964',
        '144e19ee3f16e12972695cea95ba2024b9dec3cf',
        'c55f730b452e9ac32a2fa2de53f71493712a2db5',
        '6d11dcde93afce91bc146f88e622f450201e4fff',
        '15e6e9e0530c90735c5cf589c4f7289bfff345ed',
        'fd051d9f5c663494141f9c891ae026e9ac0af62b',
        '0f6796a0845db6618f98d949a67a0979d03ec7de',
        '8c7f90c5f97c733c0975b2db5a6b8e6605549f47',
        '2fec40fa97eca571ebb00672a8c73c193f38b71f',
        '70dc23e44a76aa0eca1a59cbae657bbd3cfd2b63',
        'be974b1d2f2b57bd6d43edfdd08d4768f8e909bb',
        'b66acaaa3a29fd7a1ce8ea1654a316ca86127bdf',
        'de44eef412ce71fe5dd9275dc67e685ed1f8fd2e',
        'b7639e0a05e784364057a1c555ade7863e9e1419',
        'c318a870415a5f5eed83785e10e5a886ad8c6cc4',
        'dd01c5236d806713229fa7791e310776aa62b965',
        '7095574d01338c042aa53c08ef4d4c0c38d51359',
        '8d48c788455abfad5e18b8bde4952b9f7ce0162d',
        '0848be1ac854a26511a47e0c85a880663a975a08',
        'ef295ac38d8f7772a1ed0f382a145ef564c2ec4b',
        'e9e1b9782d61146c2795167c4d7c1510681b86a7',
        '2640a50bd6148ffe691b5ca386c533701eb14911',
        'c0a1d931b960997abdb1b727fa27c9fff26eff58',
        '77f9564a4f3a36bae4b5dee6290081f60d9be161',
        'd8554de0337f5a4fea7a227154cf572222600846',
        '542da7f7b0e2bcc8e8f7348c2502d56f6a3f615b',
        '8806f72ac4e322714f1d3f0564c2110443809810',
        '3baeb0cffbcc8647681b011bca36347008bf4f78',
        '5ddad335cf8a2deb1caad9d742c632942529e4d2',
        '5d0f9c3b15d856ea170908830b238d23a7fa066a',
        '08beb0ce46efc7a2e67170139060554e72c50cd0',
        '41e2ddd8857dbb689db88943e37b810b34e790a5',
        'de8e32fd201db2ce4d6ed13568053ed9c2a93891',
        '3f24a7c79c7047c1c65e60416276d9f3f8edbd40',
        'eef8de2ab600ebe3a866ea4db2e9906c1f1be018',
        '57879fa1fcdf116f9cc1b90be758fe422dc1ae00',
        '85f7298c6a75698b11b6b5a21750f90d345b1c42',
        'e12aae65aabfe05a2220059965d5ecca06edd269',
        '1266cc37d5d7c2243ee9c0f2a2ad4ed1da29ae0c',
        '2b57691bf0e9fdf52d06df3bdb8f195ec622ca5c',
        '39bd270f33fd585365315020ab938866f6ea061e',
        'd3fea8ea1bd7568720f782dc6415dab49bb697f5',
        '314095c559aafba9844d7d60d586d2570025d875',
        '35547500798ad2822b8b1d5d1cf4879e44596ba5',
        '470899b868390b6017bb1ec6931cb2d7d83e35b2',
        'b1c1400ee024f102417514a5449fd75c63eb95b1',
        '3d31ec420b92573da45c321741a0d0081e97c18a',
        'd85dd693901cfbd921a319e29da941ef7b4f36ef',
        '233979928224b1254b60f63c7eafd96651f9ea6a',
        '74b33ba575bb069e8d62e736dbf906dbdc668534',
        '41295d3a07b1854f2f4c77204bd926b990a93da3',
    ]);

    // True if `url` matches a collectible building texture path.
    function isCollectible(url) {
        if (typeof url !== 'string') return false;
        var m = url.match(/\/building_lib\/([a-f0-9]{40})\.png/i);
        return !!(m && HASHES.has(m[1]));
    }

    // Generate a solid hot-pink 32×32 PNG via an off-screen canvas (lazy, cached).
    var _pinkBuf = null;
    function pinkBuffer() {
        if (_pinkBuf) return _pinkBuf;
        try {
            var cv = document.createElement('canvas');
            cv.width = cv.height = 32;
            var cx = cv.getContext('2d');
            cx.fillStyle = '#FF69B4';
            cx.fillRect(0, 0, 32, 32);
            var b64 = cv.toDataURL('image/png').split(',')[1];
            var bin = atob(b64);
            var u8  = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
            _pinkBuf = u8.buffer;
        } catch (e) {
            webkit.messageHandlers.logger.postMessage('[Patcher] pinkBuffer error: ' + e);
            _pinkBuf = new ArrayBuffer(0);
        }
        return _pinkBuf;
    }

    var NativeXHR = window.XMLHttpRequest;

    // Replace the XHR constructor with one that returns a Proxy.
    // For non-collectible URLs the Proxy is fully transparent (all operations
    // forwarded to the native instance, including scanner prototype patches).
    // For collectible URLs open() skips the network call and send() fires a
    // synthetic load event carrying the pink PNG.
    window.XMLHttpRequest = function PatchedXHR() {
        var native   = new NativeXHR();
        var intercept = false;
        var rtype     = '';
        var h         = {};   // stored event handlers / listeners

        var EVT_PROPS = ['onload','onloadend','onerror','onreadystatechange',
                         'onprogress','onloadstart','onabort','ontimeout'];

        function fireSyntheticLoad() {
            var buf  = pinkBuffer();
            var resp = (rtype === 'blob')
                       ? new Blob([buf], { type: 'image/png' })
                       : buf.slice(0);

            var loadEvt = {
                type: 'load', target: proxy,
                loaded: buf.byteLength, total: buf.byteLength, lengthComputable: true,
            };
            if (h.onreadystatechange) h.onreadystatechange.call(proxy);
            if (h.onload)             h.onload.call(proxy, loadEvt);
            if (h.onloadend)          h.onloadend.call(proxy, { type: 'loadend', target: proxy });
            (h['load']    || []).forEach(function(fn) { fn.call(proxy, loadEvt); });
            (h['loadend'] || []).forEach(function(fn) { fn.call(proxy, { type: 'loadend', target: proxy }); });
        }

        var proxy = new Proxy(native, {

            get: function(t, p) {
                // ── Intercepted methods ──────────────────────────────────────
                if (p === 'open') return function(method, url) {
                    // Diagnostic: log every building_lib URL to confirm XHR is used + URL shape.
                    if (typeof url === 'string' && url.indexOf('building_lib') >= 0) {
                        var hm = url.match(/\/building_lib\/([a-f0-9]{40})\.png/i);
                        webkit.messageHandlers.logger.postMessage(
                            '[Patcher] xhr-saw building_lib hash=' + (hm ? hm[1] : '?') +
                            ' matched=' + !!(hm && HASHES.has(hm[1])) +
                            ' url=' + url.slice(0, 140));
                    }
                    intercept = isCollectible(url);
                    if (intercept) {
                        webkit.messageHandlers.logger.postMessage(
                            '[Patcher] xhr intercept ' + url.slice(url.lastIndexOf('/') + 1, -4));
                        return;   // don't open the native XHR
                    }
                    return t.open.apply(t, arguments);
                };

                if (p === 'send') return function() {
                    if (intercept) { setTimeout(fireSyntheticLoad, 0); return; }
                    return t.send.apply(t, arguments);
                };

                if (p === 'setRequestHeader') return function() {
                    if (!intercept) t.setRequestHeader.apply(t, arguments);
                };

                if (p === 'addEventListener') return function(type, fn, opts) {
                    // Always store in h so fireSyntheticLoad can reach the handler
                    // regardless of whether open() has been called yet.
                    h[type] = h[type] || [];
                    h[type].push(fn);
                    // Also register on native so non-intercepted requests work normally.
                    t.addEventListener(type, fn, opts);
                };

                if (p === 'removeEventListener') return function(type, fn, opts) {
                    if (!intercept) t.removeEventListener(type, fn, opts);
                };

                if (p === 'abort') return function() {
                    if (!intercept) t.abort();
                };

                // ── Virtual properties for the intercept case ────────────────
                if (p === 'responseType') return rtype;
                if (p === 'readyState')   return intercept ? 4   : t.readyState;
                if (p === 'status')       return intercept ? 200 : t.status;
                if (p === 'statusText')   return intercept ? 'OK': t.statusText;

                if (p === 'response') {
                    if (!intercept) return t.response;
                    var b = pinkBuffer();
                    return (rtype === 'blob')
                           ? new Blob([b], { type: 'image/png' })
                           : b.slice(0);
                }

                // ── Event-handler properties ─────────────────────────────────
                if (EVT_PROPS.indexOf(p) >= 0) return h[p] || null;

                // ── Transparent passthrough ──────────────────────────────────
                var v = t[p];
                return (typeof v === 'function') ? v.bind(t) : v;
            },

            set: function(t, p, v) {
                if (p === 'responseType') {
                    rtype = v;
                    try { t.responseType = v; } catch (_) {}
                    return true;
                }
                if (EVT_PROPS.indexOf(p) >= 0) {
                    h[p] = v;
                    try { t[p] = v; } catch (_) {}
                    return true;
                }
                try { t[p] = v; } catch (_) {}
                return true;
            },
        });

        return proxy;
    };

    // Preserve static constants and prototype so instanceof checks and
    // scanner prototype-patches remain valid.
    window.XMLHttpRequest.UNSENT           = 0;
    window.XMLHttpRequest.OPENED           = 1;
    window.XMLHttpRequest.HEADERS_RECEIVED = 2;
    window.XMLHttpRequest.LOADING          = 3;
    window.XMLHttpRequest.DONE             = 4;
    window.XMLHttpRequest.prototype        = NativeXHR.prototype;

    // Wrap fetch — in Chrome's declarativeNetRequest, resourceType "xmlhttprequest"
    // covers both XHR and fetch(), so Pinky's rules intercept fetch calls too.
    // origFetch here is jsAMF3Scanner's already-wrapped version; non-collectible
    // URLs pass through to it unchanged so AMF3 parsing keeps working.
    var origFetch = window.fetch;
    window.fetch = function(input, init) {
        var url = typeof input === 'string' ? input
                : (input && typeof input.url === 'string' ? input.url : '');
        // Diagnostic: log every building_lib URL seen via fetch.
        if (url.indexOf('building_lib') >= 0) {
            var fm = url.match(/\/building_lib\/([a-f0-9]{40})\.png/i);
            webkit.messageHandlers.logger.postMessage(
                '[Patcher] fetch-saw building_lib hash=' + (fm ? fm[1] : '?') +
                ' matched=' + !!(fm && HASHES.has(fm[1])) +
                ' url=' + url.slice(0, 140));
        }
        if (isCollectible(url)) {
            webkit.messageHandlers.logger.postMessage(
                '[Patcher] fetch intercept ' + url.slice(url.lastIndexOf('/') + 1, -4));
            var buf = pinkBuffer();
            return Promise.resolve(new Response(buf, {
                status: 200,
                statusText: 'OK',
                headers: { 'Content-Type': 'image/png' },
            }));
        }
        return origFetch.apply(this, arguments);
    };

    webkit.messageHandlers.logger.postMessage(
        '[CollectiblePatcher] ready — ' + HASHES.size + ' hashes');
})();
"""#

// ─────────────────────────────────────────────────────────────────────────────
// 5. AMF3 encoder + _TSORPC send primitive.
//    Mirrors AMFParser byte-level conventions. Round-trip equality against a
//    Phase-1-captured SendServerAction envelope should be verified in the
//    Web Inspector console before relying on dispatches in production.
// ─────────────────────────────────────────────────────────────────────────────
private let jsAMF3Encoder = #"""
(function() {
    'use strict';

    // ── Writer constructor ────────────────────────────────────────────────

    function AMFWriter() {
        this._b   = [];      // raw bytes
        this._str = {};      // string value → ref index (excludes empty string)
        this._strl = [];
        this._obj  = [];     // object identity → ref index (WeakMap-style via indexOf)
        this._tr   = {};     // traitKey → ref index
        this._trl  = [];
    }

    var W = AMFWriter.prototype;

    W.u8    = function(v) { this._b.push(v & 0xff); };
    W.u16be = function(v) { this.u8(v >> 8); this.u8(v); };
    W.s32be = function(v) {
        this.u8((v >>> 24) & 0xff);
        this.u8((v >>> 16) & 0xff);
        this.u8((v >>> 8)  & 0xff);
        this.u8(v & 0xff);
    };
    W.f64be = function(v) {
        var dv = new DataView(new ArrayBuffer(8));
        dv.setFloat64(0, v, false);
        for (var i = 0; i < 8; i++) this.u8(dv.getUint8(i));
    };

    // Variable-length 29-bit integer, big-endian 7-bit groups (MSB = continue).
    // Mirrors AMFParser.u29 exactly.
    W.u29 = function(v) {
        v &= 0x1fffffff;
        if (v < 0x80) {
            this.u8(v);
        } else if (v < 0x4000) {
            this.u8(((v >> 7) & 0x7f) | 0x80);
            this.u8(v & 0x7f);
        } else if (v < 0x200000) {
            this.u8(((v >> 14) & 0x7f) | 0x80);
            this.u8(((v >> 7)  & 0x7f) | 0x80);
            this.u8(v & 0x7f);
        } else {
            this.u8(((v >> 22) & 0x7f) | 0x80);
            this.u8(((v >> 15) & 0x7f) | 0x80);
            this.u8(((v >> 8)  & 0x7f) | 0x80);
            this.u8(v & 0xff);
        }
    };

    // AMF0 string (U16 length prefix — used in envelope target/response fields).
    W.amf0Str = function(s) {
        var enc = new TextEncoder().encode(s);
        this.u16be(enc.length);
        for (var i = 0; i < enc.length; i++) this.u8(enc[i]);
    };

    // AMF3 string with reference table. Empty string is always written inline (u29=1).
    W.amf3Str = function(s) {
        if (s === '') { this.u29(1); return; }
        if (s in this._str) { this.u29(this._str[s] << 1); return; }
        var enc = new TextEncoder().encode(s);
        this.u29((enc.length << 1) | 1);
        for (var i = 0; i < enc.length; i++) this.u8(enc[i]);
        this._str[s] = this._strl.length;
        this._strl.push(s);
    };

    W.amf3Val = function(v) {
        if (v === undefined) { this.u8(0x00); return; }
        if (v === null)      { this.u8(0x01); return; }
        if (v === false)     { this.u8(0x02); return; }
        if (v === true)      { this.u8(0x03); return; }
        if (typeof v === 'number') {
            if (Number.isInteger(v) && v >= -268435456 && v <= 268435455) {
                this.u8(0x04);
                this.u29(v < 0 ? (v + 0x20000000) : v);
            } else {
                this.u8(0x05); this.f64be(v);
            }
            return;
        }
        if (typeof v === 'string') { this.u8(0x06); this.amf3Str(v); return; }
        if (v instanceof Date) {
            this.u8(0x08);
            var idx = this._obj.indexOf(v);
            if (idx >= 0) { this.u29(idx << 1); return; }
            this._obj.push(v);
            this.u29(1);
            this.f64be(v.getTime());
            return;
        }
        if (v instanceof Uint8Array || v instanceof ArrayBuffer) {
            var ba = (v instanceof ArrayBuffer) ? new Uint8Array(v) : v;
            this.u8(0x0C);
            var bidx = this._obj.indexOf(v);
            if (bidx >= 0) { this.u29(bidx << 1); return; }
            this._obj.push(v);
            this.u29((ba.length << 1) | 1);
            for (var i = 0; i < ba.length; i++) this.u8(ba[i]);
            return;
        }
        if (Array.isArray(v)) {
            this.u8(0x09);
            var aidx = this._obj.indexOf(v);
            if (aidx >= 0) { this.u29(aidx << 1); return; }
            this._obj.push(v);
            this.u29((v.length << 1) | 1);
            this.amf3Str('');  // no associative keys
            for (var i = 0; i < v.length; i++) this.amf3Val(v[i]);
            return;
        }
        if (typeof v === 'object') {
            this.u8(0x0A);
            var oidx = this._obj.indexOf(v);
            if (oidx >= 0) { this.u29(oidx << 1); return; }
            this._obj.push(v);
            var cls = v.__class || '';
            // Externalizable: ArrayCollection / ObjectProxy.
            var isExt = cls === 'flex.messaging.io.ArrayCollection' ||
                        cls === 'mx.collections.ArrayCollection'    ||
                        cls === 'flex.messaging.io.ObjectProxy'     ||
                        cls === 'mx.utils.ObjectProxy';
            if (isExt) {
                // new trait: 0 members, externalizable=true, dynamic=false → u29(7)
                this.u29(7);
                this.amf3Str(cls);
                this.amf3Val(v.source !== undefined ? v.source : []);
                return;
            }
            var members = Object.keys(v).filter(function(k) { return k !== '__class'; });
            var trKey = cls + '|' + members.join('\x00');
            if (trKey in this._tr) {
                // trait reference: (index << 2) | 1
                this.u29((this._tr[trKey] << 2) | 1);
            } else {
                // new trait: (nm << 4) | 3  (ext=0, dyn=0)
                this.u29((members.length << 4) | 3);
                this.amf3Str(cls);
                for (var i = 0; i < members.length; i++) this.amf3Str(members[i]);
                this._tr[trKey] = this._trl.length;
                this._trl.push(trKey);
            }
            for (var i = 0; i < members.length; i++) this.amf3Val(v[members[i]]);
            return;
        }
    };

    // Build an AMF0 envelope carrying a single AMF3-typed body.
    // target: Flex remoting service method (e.g. "GameService.sendServerAction")
    // response: response counter string (e.g. "/3")
    // amf3Body: the JS value to encode as AMF3 (typically an Array of arguments)
    W.envelope = function(target, response, amf3Body) {
        this.u8(0x00); this.u8(0x03);   // AMF0 version
        this.u16be(0);                   // 0 headers
        this.u16be(1);                   // 1 body
        this.amf0Str(target);
        this.amf0Str(response);
        this.s32be(-1);                  // body length unknown
        this.u8(0x11);                   // AMF3 switch
        this.amf3Val(amf3Body);
    };

    W.toBuffer = function() {
        var ab = new ArrayBuffer(this._b.length);
        var u8 = new Uint8Array(ab);
        for (var i = 0; i < this._b.length; i++) u8[i] = this._b[i];
        return ab;
    };

    // ── _TSORPC namespace ─────────────────────────────────────────────────

    var _counter = 1;

    function getRealmUrl() {
        return window._tsoRealmUrl || null;
    }

    function uuid() {
        if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
            var r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        });
    }

    // POST an AMF envelope whose body is argsArray (an AMF3 Array).
    // Target is always the string "null" (observed from Phase 1 capture).
    // Returns Promise resolving to the parsed first response body value.
    function sendAMF(argsArray) {
        var url = getRealmUrl();
        if (!url) return Promise.reject(new Error('_TSORPC: realm URL not yet discovered'));
        var w = new AMFWriter();
        w.envelope('null', '/' + (_counter++), argsArray);
        var buf = w.toBuffer();
        webkit.messageHandlers.logger.postMessage('[AMF3:out] POST bytes=' + buf.byteLength);
        return fetch(url, {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-amf' },
            body: buf,
        }).then(function(resp) {
            return resp.arrayBuffer();
        }).then(function(ab) {
            if (window._TSOAMFParser) {
                try {
                    var p = new window._TSOAMFParser(ab);
                    var bodies = p.parseEnvelope();
                    return bodies.length > 0 ? bodies[0].value : null;
                } catch (_) {}
            }
            return ab;
        });
    }

    // Build the full RemotingMessage → dServerCall → dServerAction → VO chain
    // and POST it. opcode=95 for specialist tasks.
    // subTaskID encodes the deposit/task type (0 = default / any).
    // Key order in each object literal must match the observed trait member order.
    function dispatchSpecialist(opts) {
        var ctx = window._tsoAuthCtx;
        if (!ctx || !ctx.dsoAuthToken) {
            webkit.messageHandlers.logger.postMessage(
                '[_TSORPC] auth not ready — make a manual game action first');
            return Promise.reject(new Error('auth not ready'));
        }

        var uid1      = opts.uid1 | 0;
        var uid2      = opts.uid2 | 0;
        var subTaskID = (opts.taskCode !== undefined ? opts.taskCode : (opts.subTaskID | 0));
        var grid      = opts.targetGrid | 0;
        var endGrid   = opts.endGrid    | 0;

        // ── VO objects — member key order matches observed AMF3 trait definitions ──

        var uniqueID = {
            __class:   'defaultGame.Communication.VO.dUniqueID',
            uniqueID1: uid1,
            uniqueID2: uid2,
        };
        var taskVO = {
            __class:     'defaultGame.Communication.VO.dStartSpecialistTaskVO',
            uniqueID:    uniqueID,
            subTaskID:   subTaskID,
            paramString: null,
        };
        var action = {
            __class:  'defaultGame.Communication.VO.dServerAction',
            type:     0,
            grid:     grid,
            endGrid:  endGrid,
            data:     taskVO,
        };
        var call = {
            __class:               'defaultGame.Communication.VO.dServerCall',
            type:                  95,
            zoneID:                ctx.zoneID,
            data:                  action,
            dsoAuthUser:           ctx.dsoAuthUser,
            dsoAuthToken:          ctx.dsoAuthToken,
            dsoAuthRandomClientID: ctx.dsoAuthRandomClientID,
        };
        var headers = {
            __class:    '',
            DSEndpoint: 'SMC-Endpoint',
            DSId:       ctx.DSId,
        };
        var msg = {
            __class:        'flex.messaging.messages.RemotingMessage',
            source:         'com.bluebyte.game.servlet.EventHandler',
            operation:      'ExecuteServerCall',
            parameters:     null,
            remoteUsername: null,
            remotePassword: null,
            correlationId:  null,
            body:           [call],
            clientId:       null,
            destination:    'SMC',
            headers:        headers,
            messageId:      uuid(),
            timestamp:      0,
            timeToLive:     0,
        };

        webkit.messageHandlers.logger.postMessage(
            '[_TSORPC] dispatchSpecialist uid=' + uid1 + ':' + uid2 +
            ' subTaskID=' + subTaskID + ' zone=' + ctx.zoneID);

        return sendAMF([msg]).then(function(result) {
            webkit.messageHandlers.logger.postMessage(
                '[_TSORPC] ack: ' + JSON.stringify(result));
        }).catch(function(e) {
            webkit.messageHandlers.logger.postMessage('[_TSORPC] error: ' + e);
        });
    }

    window._TSORPC = { sendAMF: sendAMF, dispatchSpecialist: dispatchSpecialist };
    window._TSOAMFWriter = AMFWriter;

    // Register TSOBridge handlers for Swift-initiated dispatches.
    if (window.TSOBridge) {
        window.TSOBridge.register('DISPATCH_SPECIALIST', function(p) {
            dispatchSpecialist(p);
        });
        window.TSOBridge.register('RPC_SEND', function(p) {
            sendAMF(p.args || []);
        });
    }

    webkit.messageHandlers.logger.postMessage('[AMF3Encoder] ready');
})();
"""#
