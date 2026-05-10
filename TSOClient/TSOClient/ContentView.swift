import SwiftUI
import WebKit

// MARK: - WebView (NSViewRepresentable)

struct WebView: NSViewRepresentable {
    let url: URL
    var store: CollectiblesStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.setURLSchemeHandler(HighlightSchemeHandler(), forURLScheme: "tso-asset")

        let controller = config.userContentController

        // JS execution order matters: bridge first, then scanner, then patcher.
        // jsOverlay and jsURLRewriter are disabled — collectible highlighting is now
        // done by jsCollectiblePatcher (texture substitution via fetch interception),
        // which requires no overlay canvas or calibration.
        for (source, frame) in [
            (jsBridge,              false),
            // (jsOverlay,          false),  // disabled: replaced by texture patcher
            (jsAMF3Scanner,         false),
            // (jsURLRewriter,      false),  // disabled: dormant under Unity client
            (jsCollectiblePatcher,  false),
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
        return webView
    }

    // Only load once — guard prevents reloading on every SwiftUI update.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

        var store: CollectiblesStore
        weak var webView: WKWebView?

        init(store: CollectiblesStore) { self.store = store }

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

            // All SwiftUI mutations on main thread.
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
                        self.webView?.evaluateJavaScript(
                            "window._TSOOverlay?.setCollectibles([]);window._TSOOverlay?.resyncCamera()",
                            completionHandler: nil)
                    }
                case .calibrationDone(let payload):
                    print("[TSO] Calibration: tileHW=\(payload.tileHW) tileHH=\(payload.tileHH) origin=(\(payload.originX),\(payload.originY))")
                }
            }
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @State private var store = CollectiblesStore()

    var body: some View {
        WebView(url: URL(string: "https://www.thesettlersonline.com/en/homepage")!,
                store: store)
            .frame(minWidth: 1024, minHeight: 768)
    }
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
// 2. Overlay — transparent canvas drawn over the game; isometric coordinate
//    system with two-point calibration. Camera pan is tracked via a
//    requestAnimationFrame loop that reads game-runtime globals (Pinky-style)
//    rather than MutationObserver — TSO HTML5 pans by internal canvas transform,
//    not CSS style mutations on the canvas element.
// ─────────────────────────────────────────────────────────────────────────────
private let jsOverlay = #"""
(function() {
    'use strict';

    // Calibration — world-space so it survives camera pans.
    // AMF (gx,gy) are axis-aligned with screen: gx roughly horizontal, gy roughly vertical.
    // screenX = gx*scaleX + originX - camera.x
    // screenY = gy*scaleY + originY - camera.y
    var cal = {
        originX: 0, originY: 0,
        scaleX:  120, scaleY: 40,
        shearXY: 0,   shearYX: 0,  // off-diagonal affine: screenX += shearXY*gy, screenY += shearYX*gx
    };

    var style = {
        markerRadius: 14,
        markerColor:  '#FFD700',
        markerAlpha:  0.85,
        glowColor:    '#FFD700',
        glowBlur:     22,
    };

    var collectibles = [];
    var enabled      = true;
    var overlay, ctx;

    var camera    = { x: 0, y: 0 };
    var _synthCam = { x: 0, y: 0 };
    var _dragLast  = null;
    var _lastTap   = null;

    var _mayorGx = -1, _mayorGy = -1;
    var _allBuildings    = [];   // [{x, y, name}] from scanner
    var _cachedMapWidth  = 0, _cachedMapHeight = 0;

    // ── Calibration state ─────────────────────────────────────────────────
    // ADJUST: fine-tune with keys, Alt+click for 2pt refine, Enter to save.
    // Enter → save; Esc → restore last saved; Shift+C → toggle.
    var _calMode  = false;
    var _calPhase = 'ADJUST';
    var _anchorA  = null;           // {gx, gy, sx, sy}
    var _anchorB  = null;
    var _cursorSX = -1, _cursorSY = -1;

    var _pickupPoints = [];

    // ── Canvas lifecycle ──────────────────────────────────────────────────

    function ensureOverlay() {
        if (overlay && document.body.contains(overlay)) return true;
        var wrap = document.createElement('div');
        wrap.id = '_tso_overlay_wrap';
        wrap.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:50;overflow:hidden;';
        overlay = document.createElement('canvas');
        overlay.id = '_tso_overlay';
        overlay.style.cssText = 'position:absolute;top:0;left:0;';
        overlay.width  = window.innerWidth;
        overlay.height = window.innerHeight;
        wrap.appendChild(overlay);
        document.body.appendChild(wrap);
        ctx = overlay.getContext('2d');
        window.addEventListener('resize', function() {
            overlay.width  = window.innerWidth;
            overlay.height = window.innerHeight;
            render();
        });
        return true;
    }

    // ── Coordinate transforms ─────────────────────────────────────────────

    function gridToScreen(gx, gy) {
        return {
            x: cal.scaleX*gx + cal.shearXY*gy + cal.originX - camera.x,
            y: cal.shearYX*gx + cal.scaleY*gy  + cal.originY - camera.y,
        };
    }

    function screenToGrid(sx, sy) {
        var det = cal.scaleX*cal.scaleY - cal.shearXY*cal.shearYX;
        if (Math.abs(det) < 0.001) return { gx: 0, gy: 0 };
        var wx = sx + camera.x - cal.originX;
        var wy = sy + camera.y - cal.originY;
        return {
            gx: ( cal.scaleY*wx - cal.shearXY*wy) / det,
            gy: (-cal.shearYX*wx + cal.scaleX*wy) / det,
        };
    }

    // ── Rendering ─────────────────────────────────────────────────────────

    function drawMarker(sx, sy) {
        ctx.save();
        ctx.shadowColor = style.glowColor; ctx.shadowBlur = style.glowBlur;
        ctx.globalAlpha = style.markerAlpha; ctx.fillStyle = style.markerColor;
        ctx.beginPath(); ctx.arc(sx, sy, style.markerRadius, 0, Math.PI * 2); ctx.fill();
        ctx.shadowBlur = 0; ctx.globalAlpha = 1; ctx.fillStyle = '#FFFFFF';
        ctx.beginPath(); ctx.arc(sx, sy, 4, 0, Math.PI * 2); ctx.fill();
        ctx.restore();
    }

    function render() {
        if (!ensureOverlay() || !ctx) return;
        ctx.clearRect(0, 0, overlay.width, overlay.height);
        var w = overlay.width, h = overlay.height;

        // Collectible markers
        if (enabled && collectibles.length > 0) {
            for (var i = 0; i < collectibles.length; i++) {
                var c = collectibles[i];
                var s = gridToScreen(c.x, c.y);
                if (s.x <= -60 || s.x >= w + 60 || s.y <= -60 || s.y >= h + 60) continue;
                drawMarker(s.x, s.y);
            }
        }

        if (!_calMode) return;

        // ── Cal-mode diagnostics ──────────────────────────────────────────

        // All named buildings as labeled cyan dots.
        // The user aligns these dots with the actual buildings visible in the game.
        ctx.save();
        ctx.font = '9px monospace';
        for (var bi = 0; bi < _allBuildings.length; bi++) {
            var b  = _allBuildings[bi];
            var bs = gridToScreen(b.x, b.y);
            if (bs.x < -40 || bs.x > w + 40 || bs.y < -40 || bs.y > h + 40) continue;
            ctx.globalAlpha = 0.50; ctx.fillStyle = '#00FFFF';
            ctx.beginPath(); ctx.arc(bs.x, bs.y, 4, 0, 6.283); ctx.fill();
            if (b.name) {
                ctx.globalAlpha = 0.70; ctx.fillStyle = '#AAFFFF';
                ctx.fillText(b.name.slice(0, 16), bs.x + 6, bs.y + 3);
            }
        }
        ctx.restore();

        // 7×7 rectangular reference-grid probe centred on Mayor (or anchor if set)
        var pgx = _anchorA ? _anchorA.gx : _mayorGx;
        var pgy = _anchorA ? _anchorA.gy : _mayorGy;
        if (pgx >= 0) {
            ctx.save();
            ctx.strokeStyle = '#FF00FF'; ctx.lineWidth = 1; ctx.globalAlpha = 0.28;
            for (var dg = -3; dg <= 3; dg++) {
                ctx.beginPath();
                for (var dv = -3; dv <= 3; dv++) {
                    var ptA = gridToScreen(pgx + dv, pgy + dg);
                    if (dv === -3) ctx.moveTo(ptA.x, ptA.y); else ctx.lineTo(ptA.x, ptA.y);
                }
                ctx.stroke();
                ctx.beginPath();
                for (var du = -3; du <= 3; du++) {
                    var ptB = gridToScreen(pgx + dg, pgy + du);
                    if (du === -3) ctx.moveTo(ptB.x, ptB.y); else ctx.lineTo(ptB.x, ptB.y);
                }
                ctx.stroke();
            }
            ctx.globalAlpha = 0.60; ctx.fillStyle = '#FF00FF';
            for (var ix = -3; ix <= 3; ix++) {
                for (var iy = -3; iy <= 3; iy++) {
                    var ip = gridToScreen(pgx + ix, pgy + iy);
                    if (ip.x < -20 || ip.x > w + 20 || ip.y < -20 || ip.y > h + 20) continue;
                    ctx.beginPath(); ctx.arc(ip.x, ip.y, 3, 0, 6.283); ctx.fill();
                }
            }
            ctx.restore();
        }

        // Map-extent diamond
        if (_cachedMapWidth > 0 && _cachedMapHeight > 0) {
            var mw = _cachedMapWidth - 1, mh = _cachedMapHeight - 1;
            var corners = [
                { gx: 0,  gy: 0,  label: '(0,0)' },
                { gx: mw, gy: 0,  label: '(W,0)' },
                { gx: 0,  gy: mh, label: '(0,H)' },
                { gx: mw, gy: mh, label: '(W,H)' },
            ];
            var cs = corners.map(function(c) { return gridToScreen(c.gx, c.gy); });
            ctx.save();
            ctx.strokeStyle = '#4488FF'; ctx.lineWidth = 1.5; ctx.globalAlpha = 0.55;
            ctx.beginPath();
            ctx.moveTo(cs[0].x, cs[0].y); ctx.lineTo(cs[1].x, cs[1].y);
            ctx.lineTo(cs[3].x, cs[3].y); ctx.lineTo(cs[2].x, cs[2].y);
            ctx.closePath(); ctx.stroke();
            ctx.fillStyle = '#4488FF'; ctx.font = 'bold 10px monospace'; ctx.globalAlpha = 0.85;
            for (var ci = 0; ci < corners.length; ci++) {
                if (cs[ci].x < -80 || cs[ci].x > w + 80 || cs[ci].y < -80 || cs[ci].y > h + 80) continue;
                ctx.beginPath(); ctx.arc(cs[ci].x, cs[ci].y, 5, 0, 6.283); ctx.fill();
                ctx.fillText(corners[ci].label, cs[ci].x + 8, cs[ci].y + 4);
            }
            ctx.restore();
        }

        // Second-anchor crosshair (green) — set via Alt+click on a collectible
        if (_anchorB) {
            ctx.save();
            ctx.strokeStyle = '#00FF88'; ctx.lineWidth = 2; ctx.globalAlpha = 0.9;
            var bx = _anchorB.sx, by = _anchorB.sy;
            ctx.beginPath(); ctx.moveTo(bx - 16, by); ctx.lineTo(bx + 16, by); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(bx, by - 16); ctx.lineTo(bx, by + 16); ctx.stroke();
            ctx.beginPath(); ctx.arc(bx, by, 7, 0, 6.283); ctx.stroke();
            ctx.fillStyle = '#00FF88'; ctx.font = 'bold 9px monospace'; ctx.globalAlpha = 0.85;
            ctx.fillText('B(' + _anchorB.gx + ',' + _anchorB.gy + ')', bx + 10, by + 4);
            ctx.restore();
        }

        // Mayor anchor crosshair
        if (_anchorA) {
            ctx.save();
            ctx.strokeStyle = '#FF00FF'; ctx.lineWidth = 3; ctx.globalAlpha = 0.9;
            var ax = _anchorA.sx, ay = _anchorA.sy;
            ctx.beginPath(); ctx.moveTo(ax - 22, ay); ctx.lineTo(ax + 22, ay); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(ax, ay - 22); ctx.lineTo(ax, ay + 22); ctx.stroke();
            ctx.beginPath(); ctx.arc(ax, ay, 10, 0, 6.283); ctx.stroke();
            ctx.restore();
        }

        // HUD
        var curGrid = (_anchorA && _cursorSX >= 0) ? screenToGrid(_cursorSX, _cursorSY) : null;
        var hint = _calPhase === 'WAIT_CLICK_A' ? 'Click the blue collectible marked 1' :
                   _calPhase === 'WAIT_CLICK_B' ? 'Click the blue collectible marked 2' :
                   _calPhase === 'WAIT_CLICK_C' ? 'Click the blue collectible marked 3' :
                   'Arrows=nudge  [/]=scaleX  Alt+[/]=scaleY  {/}=shearXY  Alt+{/}=shearYX  Shift=fine(±0.05)  Alt+click=2pt  Enter=save  Esc=cancel';
        var shearStr = _calPhase === 'ADJUST'
                       ? '  shear=(' + cal.shearXY.toFixed(2) + ',' + cal.shearYX.toFixed(2) + ')' : '';
        var hud = '[' + _calPhase + ']  scaleX=' + cal.scaleX.toFixed(2) +
                  '  scaleY=' + cal.scaleY.toFixed(2) + shearStr +
                  (curGrid ? '  cur=(' + curGrid.gx.toFixed(1) + ',' + curGrid.gy.toFixed(1) + ')' : '') +
                  '  ' + hint;
        ctx.save();
        ctx.fillStyle = 'rgba(0,0,0,0.72)';
        ctx.fillRect(4, 4, w - 8, 30);
        ctx.fillStyle = '#FFFFFF'; ctx.font = 'bold 12px monospace';
        ctx.fillText(hud, 10, 25);
        ctx.restore();
    }

    // ── Calibration helpers ───────────────────────────────────────────────

    function recomputeOriginFromA() {
        if (!_anchorA) return;
        cal.originX = _anchorA.sx - cal.scaleX*_anchorA.gx - cal.shearXY*_anchorA.gy;
        cal.originY = _anchorA.sy - cal.shearYX*_anchorA.gx - cal.scaleY*_anchorA.gy;
    }

    // ── Calibration persistence ───────────────────────────────────────────
    var CAL_KEY = '_tso_cal_v6';

    function saveCalibration() {
        if (!_anchorA) {
            webkit.messageHandlers.logger.postMessage('[Overlay] Cal not saved — click Mayor first');
            return;
        }
        try {
            var d = {
                scaleX: cal.scaleX, scaleY: cal.scaleY,
                shearXY: cal.shearXY, shearYX: cal.shearYX,
                anchorA: { gx: _anchorA.gx, gy: _anchorA.gy, sx: _anchorA.sx, sy: _anchorA.sy },
                ww: window.innerWidth, wh: window.innerHeight,
            };
            localStorage.setItem(CAL_KEY, JSON.stringify(d));
            webkit.messageHandlers.logger.postMessage(
                '[Overlay] Cal saved v6: scaleX=' + cal.scaleX.toFixed(4) +
                ' scaleY=' + cal.scaleY.toFixed(4) +
                ' Mayor=(' + _anchorA.sx.toFixed(1) + ',' + _anchorA.sy.toFixed(1) + ')' +
                ' at ' + window.innerWidth + 'x' + window.innerHeight);
        } catch(e) {}
    }

    function loadStoredCalibration() {
        try {
            var d = JSON.parse(localStorage.getItem(CAL_KEY) || 'null');
            if (!d || !d.anchorA) return null;
            cal.scaleX = d.scaleX; cal.scaleY = d.scaleY;
            cal.shearXY = d.shearXY || 0; cal.shearYX = d.shearYX || 0;
            webkit.messageHandlers.logger.postMessage(
                '[Overlay] Cal loaded v6: scaleX=' + cal.scaleX.toFixed(4) + ' scaleY=' + cal.scaleY.toFixed(4) +
                ' shearXY=' + cal.shearXY.toFixed(4) + ' shearYX=' + cal.shearYX.toFixed(4));
            return d;
        } catch(e) { return null; }
    }

    function autoCalibrateFromMayor(gx, gy) {
        _mayorGx = gx; _mayorGy = gy;
        _synthCam.x = 0; _synthCam.y = 0;
        camera.x = 0; camera.y = 0; _lastCamX = 0; _lastCamY = 0;
        try {
            var d = JSON.parse(localStorage.getItem(CAL_KEY) || 'null');
            if (d && d.anchorA && typeof d.scaleX === 'number') {
                cal.scaleX = d.scaleX; cal.scaleY = d.scaleY;
                cal.shearXY = d.shearXY || 0; cal.shearYX = d.shearYX || 0;
                var winScaleX = window.innerWidth  / d.ww;
                var winScaleY = window.innerHeight / d.wh;
                _anchorA = { gx: gx, gy: gy,
                             sx: d.anchorA.sx * winScaleX, sy: d.anchorA.sy * winScaleY };
                recomputeOriginFromA();
                _pickupPoints = [{ gx: gx, gy: gy, wx: _anchorA.sx, wy: _anchorA.sy }];
                render();
                webkit.messageHandlers.logger.postMessage(
                    '[Overlay] Warm start v6. Mayor=(' + _anchorA.sx.toFixed(1) + ',' + _anchorA.sy.toFixed(1) + ')' +
                    ' origin=(' + cal.originX.toFixed(1) + ',' + cal.originY.toFixed(1) + ')');
            } else {
                // No saved cal — enter ADJUST with a rough initial scale; user tweaks with keys.
                _calMode  = true;
                _calPhase = 'ADJUST';
                _anchorB  = null;
                if (_cachedMapWidth > 0 && _cachedMapHeight > 0) {
                    cal.scaleX = (window.innerWidth  * 0.8) / _cachedMapWidth;
                    cal.scaleY = (window.innerHeight * 0.8) / _cachedMapHeight;
                }
                _anchorA = { gx: gx, gy: gy,
                             sx: window.innerWidth  / 2,
                             sy: window.innerHeight / 2 };
                recomputeOriginFromA();
                render();
                webkit.messageHandlers.logger.postMessage(
                    '[Overlay] No saved cal — use {/} keys to calibrate, then Enter to save.');
            }
        } catch(e) {}
    }

    function recordPickupCalibPoint(gx, gy) {
        if (!_lastTap || Date.now() - _lastTap.time > 15000) {
            webkit.messageHandlers.logger.postMessage(
                '[Overlay] Pickup (' + gx + ',' + gy + ') — no recent tap, skipping cal');
            return;
        }
        var tapX = _lastTap.x + camera.x;   // world-space X
        _pickupPoints.push({ gx: gx, gy: gy, wx: tapX, wy: _lastTap.y + camera.y });
        var n = _pickupPoints.length;
        webkit.messageHandlers.logger.postMessage(
            '[Overlay] Pickup anchor #' + n + ': (' + gx + ',' + gy + ') world-x=' + tapX.toFixed(1));

        if (n >= 2 && _anchorA) {
            // X-only scaleX solve using Mayor (p0) and this pickup.
            // Y click is unreliable (sprite sits above ground tile); X is symmetric.
            var p0 = _pickupPoints[0];
            var dgx = gx - p0.gx;
            if (Math.abs(dgx) < 2) {
                webkit.messageHandlers.logger.postMessage(
                    '[Overlay] Pickup too close in grid-X (dgx=' + dgx + '), skipping');
                _pickupPoints.pop(); return;
            }
            var newSX = (tapX - p0.wx) / dgx;
            if (newSX < 10 || newSX > 400) {
                webkit.messageHandlers.logger.postMessage(
                    '[Overlay] Pickup scaleX=' + newSX.toFixed(2) + ' out of [10,400], skipping');
                _pickupPoints.pop(); return;
            }
            cal.scaleX = newSX;
            recomputeOriginFromA();
            if (_anchorA) saveCalibration();
            webkit.messageHandlers.logger.postMessage(
                '[Overlay] Pickup refined: scaleX=' + cal.scaleX.toFixed(4));
        } else if (n === 1 && _anchorA) {
            // Single pickup with anchor A: snap originX from X (don't change scale)
            cal.originX = tapX - gx * cal.scaleX;
            _anchorA.sx = tapX - camera.x;
            webkit.messageHandlers.logger.postMessage('[Overlay] Origin snapped from pickup X');
        }
        render();
    }

    // ── rAF camera loop ───────────────────────────────────────────────────

    var _lastCamX = 0, _lastCamY = 0;

    function rafLoop() {
        if (_synthCam.x !== _lastCamX || _synthCam.y !== _lastCamY) {
            camera.x = _synthCam.x; camera.y = _synthCam.y;
            _lastCamX = _synthCam.x; _lastCamY = _synthCam.y;
            render();
        }
        requestAnimationFrame(rafLoop);
    }

    // ── Pointer / mouse tracking ──────────────────────────────────────────

    function initPointerDrag() {
        window.addEventListener('pointerdown', function(e) {
            if (!e.isPrimary || (e.target && e.target.id === '_tso_overlay')) return;
            _dragLast = { x: e.clientX, y: e.clientY };
        }, { capture: true, passive: true });

        window.addEventListener('pointermove', function(e) {
            if (!e.isPrimary) return;
            _cursorSX = e.clientX; _cursorSY = e.clientY;
            if (!e.buttons || !_dragLast || (e.target && e.target.id === '_tso_overlay')) return;
            var m = 4;
            if (e.clientX <= m || e.clientX >= window.innerWidth  - m ||
                e.clientY <= m || e.clientY >= window.innerHeight - m) {
                _dragLast = { x: e.clientX, y: e.clientY }; return;
            }
            _synthCam.x -= e.clientX - _dragLast.x;
            _synthCam.y -= e.clientY - _dragLast.y;
            _dragLast = { x: e.clientX, y: e.clientY };
        }, { capture: true, passive: true });

        window.addEventListener('mousemove', function(e) {
            if (!_calMode) return;
            _cursorSX = e.clientX; _cursorSY = e.clientY;
            render();
        }, { capture: true, passive: true });

        window.addEventListener('pointerup', function(e) {
            if (e.isPrimary) _dragLast = null;
        }, { capture: true, passive: true });
        window.addEventListener('pointercancel', function(e) {
            // Do NOT clear _dragLast — Unity setPointerCapture fires cancel mid-drag
        }, { capture: true, passive: true });

        window.addEventListener('mouseup', function(e) {
            // Alt+click in ADJUST → two-point refinement using a nearby collectible
            if (_calMode && _calPhase === 'ADJUST' && e.button === 0 && e.altKey &&
                _anchorA && collectibles.length > 0) {
                var minD2 = Infinity, bestC = null;
                for (var ci = 0; ci < collectibles.length; ci++) {
                    var ps = gridToScreen(collectibles[ci].x, collectibles[ci].y);
                    var d2 = (ps.x - e.clientX) * (ps.x - e.clientX) +
                             (ps.y - e.clientY) * (ps.y - e.clientY);
                    if (d2 < minD2) { minD2 = d2; bestC = collectibles[ci]; }
                }
                if (bestC) {
                    _anchorB = { gx: bestC.x, gy: bestC.y, sx: e.clientX, sy: e.clientY };
                    var dgx = _anchorB.gx - _anchorA.gx;
                    var dgy = _anchorB.gy - _anchorA.gy;
                    var dsx = _anchorB.sx - _anchorA.sx;
                    var dsy = _anchorB.sy - _anchorA.sy;
                    var changed = false;
                    if (Math.abs(dgx) > 2) { cal.scaleX = dsx / dgx; changed = true; }
                    if (Math.abs(dgy) > 2) { cal.scaleY = dsy / dgy; changed = true; }
                    if (changed) recomputeOriginFromA();
                    webkit.messageHandlers.logger.postMessage(
                        '[Overlay] 2pt-cal: B=(' + _anchorB.gx + ',' + _anchorB.gy + ')' +
                        ' click=(' + e.clientX + ',' + e.clientY + ')' +
                        ' scaleX=' + cal.scaleX.toFixed(3) + ' scaleY=' + cal.scaleY.toFixed(3));
                    render();
                }
                return;
            }

            _lastTap = { time: Date.now(), x: e.clientX, y: e.clientY };
            webkit.messageHandlers.logger.postMessage('[Overlay] Tap: (' + e.clientX + ',' + e.clientY + ') btn=' + e.button);
        }, { capture: true, passive: true });
    }

    // ── Public API ────────────────────────────────────────────────────────

    window._TSOOverlay = {
        setCollectibles: function(items) { collectibles = items; render(); },
        setBuildings:    function(items) { _allBuildings = items; },
        setMapDims:      function(w, h)  { _cachedMapWidth = w; _cachedMapHeight = h; },
        setEnabled:      function(v)     { enabled = v; render(); },
        setColor:        function(hex)   { style.markerColor = hex; style.glowColor = hex; render(); },
        render: render,
        getCalibration: function() { return Object.assign({}, cal); },
        getCamera:      function() { return Object.assign({}, camera); },
        autoCalibrateFromMayor: autoCalibrateFromMayor,
        recordPickupCalibPoint: recordPickupCalibPoint,
        resyncCamera: function() {
            _synthCam.x = 0; _synthCam.y = 0;
            camera.x = 0; camera.y = 0; _lastCamX = 0; _lastCamY = 0;
            render();
            webkit.messageHandlers.logger.postMessage('[Overlay] Camera resynced');
        },
        toggleCalMode: function() {
            _calMode = !_calMode;
            _calPhase = 'ADJUST';
            if (_calMode) {
                webkit.messageHandlers.logger.postMessage('[Overlay] Cal mode ON — {/} scaleX  Alt+{/} scaleY  Ctrl+{/} shearXY  Ctrl+Alt+{/} shearYX  Shift=fine  Arrows=nudge  Enter=save');
            } else {
                webkit.messageHandlers.logger.postMessage('[Overlay] Cal mode OFF');
            }
            render();
        },
        calibrate: function(gx1, gy1, sx1, sy1, gx2, gy2, sx2, sy2) {
            // Swift two-point bridge (kept for compatibility)
            var wx1 = sx1 + camera.x, wy1 = sy1 + camera.y;
            var wx2 = sx2 + camera.x, wy2 = sy2 + camera.y;
            if (gx2 !== gx1) cal.scaleX = (wx2 - wx1) / (gx2 - gx1);
            if (gy2 !== gy1) cal.scaleY = (wy2 - wy1) / (gy2 - gy1);
            cal.originX = wx1 - gx1 * cal.scaleX;
            cal.originY = wy1 - gy1 * cal.scaleY;
            render();
        },
    };

    window.addEventListener('keydown', function(e) {
        // Debug: confirm handler fires for our keys and show cal state.
        var _dbgKeys = { Digit1:1, KeyR:1, KeyC:1, BracketLeft:1, BracketRight:1,
                         ArrowLeft:1, ArrowRight:1, ArrowUp:1, ArrowDown:1,
                         Enter:1, Escape:1 };
        var _isCurly = e.key === '{' || e.key === '}';
        if (_dbgKeys[e.code] || _isCurly) {
            webkit.messageHandlers.logger.postMessage(
                '[Overlay] key=' + e.key + '(' + e.code + ') shift=' + e.shiftKey +
                ' alt=' + e.altKey + ' calMode=' + _calMode + ' phase=' + _calPhase);
        }
        if (e.code === 'Digit1' && !e.shiftKey && !e.ctrlKey && !e.metaKey && !e.altKey) {
            _synthCam.x = 0; _synthCam.y = 0;
            camera.x = 0; camera.y = 0; _lastCamX = 0; _lastCamY = 0;
            render();
            webkit.messageHandlers.logger.postMessage('[Overlay] Key-1 camera resync');
        }
        if (e.shiftKey && e.code === 'KeyR') { window._TSOOverlay.resyncCamera(); return; }
        if (e.shiftKey && e.code === 'KeyC') { window._TSOOverlay.toggleCalMode(); return; }
        if (!_calMode || _calPhase !== 'ADJUST') return;

        var isArrow   = e.code === 'ArrowLeft'  || e.code === 'ArrowRight' ||
                        e.code === 'ArrowUp'    || e.code === 'ArrowDown';
        var isBracket = e.code === 'BracketLeft' || e.code === 'BracketRight' ||
                        e.key === '{' || e.key === '}';
        var isConfirm = e.code === 'Enter' || e.code === 'Escape';
        if (isArrow || isBracket || isConfirm) { e.preventDefault(); e.stopPropagation(); }

        // Arrow keys nudge the Mayor anchor (shifts origin, keeping tile sizes)
        if (isArrow && _anchorA) {
            var step = e.shiftKey ? 1 : 5;
            if (e.code === 'ArrowLeft')  _anchorA.sx -= step;
            if (e.code === 'ArrowRight') _anchorA.sx += step;
            if (e.code === 'ArrowUp')    _anchorA.sy -= step;
            if (e.code === 'ArrowDown')  _anchorA.sy += step;
            recomputeOriginFromA(); render();
        }

        // [ / ] → scaleX  /  Alt+[ / ] → scaleY   plain=±0.5  Shift=fine±0.05
        if (e.code === 'BracketLeft' || e.code === 'BracketRight') {
            var step = e.shiftKey ? 0.05 : 0.5;
            var dir  = e.code === 'BracketLeft' ? -1 : 1;
            if (e.altKey) {
                cal.scaleY = Math.max(-500, Math.min(500, cal.scaleY + dir * step));
            } else {
                cal.scaleX = Math.max(-500, Math.min(500, cal.scaleX + dir * step));
            }
            recomputeOriginFromA(); render();
        }

        // { / } → shearXY  /  Alt+{ / } → shearYX   plain=±0.5  Shift=fine±0.05
        if (e.key === '{' || e.key === '}') {
            var step = e.shiftKey ? 0.05 : 0.5;
            var dir  = e.key === '{' ? -1 : 1;
            if (e.altKey) {
                cal.shearYX = Math.max(-500, Math.min(500, cal.shearYX + dir * step));
            } else {
                cal.shearXY = Math.max(-500, Math.min(500, cal.shearXY + dir * step));
            }
            recomputeOriginFromA(); render();
        }

        if (e.code === 'Enter') { saveCalibration(); _calMode = false; render(); }

        if (e.code === 'Escape') {
            _calMode = false;
            try {
                var prev = JSON.parse(localStorage.getItem(CAL_KEY) || 'null');
                if (prev && prev.anchorA) {
                    cal.scaleX = prev.scaleX; cal.scaleY = prev.scaleY;
                    _anchorA = { gx: prev.anchorA.gx, gy: prev.anchorA.gy,
                                 sx: prev.anchorA.sx * (window.innerWidth  / prev.ww),
                                 sy: prev.anchorA.sy * (window.innerHeight / prev.wh) };
                    recomputeOriginFromA();
                }
            } catch(_) {}
            render();
            webkit.messageHandlers.logger.postMessage('[Overlay] Cal cancelled');
        }
    }, { capture: true });

    window.TSOBridge.register('SET_OVERLAY',       function(p) { window._TSOOverlay.setEnabled(!!p.enabled); });
    window.TSOBridge.register('SET_OVERLAY_COLOR', function(p) { window._TSOOverlay.setColor(p.color); });
    window.TSOBridge.register('RENDER',            function()  { window._TSOOverlay.render(); });
    window.TSOBridge.register('CALIBRATE',         function(p) {
        window._TSOOverlay.calibrate(p.gx1, p.gy1, p.sx1, p.sy1, p.gx2, p.gy2, p.sx2, p.sy2);
    });

    function init() {
        loadStoredCalibration();
        ensureOverlay();
        initPointerDrag();
        rafLoop();
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
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
                if (_prevCollectibles !== null && _prevCollectibles[dKey] && window._TSOOverlay) {
                    var dit = _prevCollectibles[dKey];
                    window._TSOOverlay.recordPickupCalibPoint(dit.x, dit.y);
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

        // Push map dims and collectibles first so autoCalibrateFromMayor
        // can pick calibration targets from the collectible list.
        if (window._TSOOverlay && result.mapWidth > 0 && ctx.allBuildings.length > 0) {
            var bldgPos = [];
            for (var bii = 0; bii < ctx.allBuildings.length; bii++) {
                var bgi = detectPosition(ctx.allBuildings[bii]);
                if (bgi < 0) continue;
                var bld = ctx.allBuildings[bii];
                bldgPos.push({
                    x:    bgi % result.mapWidth,
                    y:    Math.floor(bgi / result.mapWidth),
                    name: (typeof bld.buildingName_string === 'string' ? bld.buildingName_string
                          : typeof bld.skin === 'string'               ? bld.skin : ''),
                });
            }
            window._TSOOverlay.setBuildings(bldgPos);
            window._TSOOverlay.setMapDims(result.mapWidth, result.mapHeight);
        }
        if (window._TSOOverlay) window._TSOOverlay.setCollectibles(result.items);

        // ── Mayor's house auto-calibration (zone-load responses only) ─────
        if (ctx.maps.length > 0 && window._TSOOverlay && result.mapWidth > 0) {
            for (var mi = 0; mi < ctx.allBuildings.length; mi++) {
                var mb = ctx.allBuildings[mi];
                if ((mb.buildingName_string || mb.skin || '') === 'Mayorhouse') {
                    var mgi = mb.buildingGrid | 0;
                    window._TSOOverlay.autoCalibrateFromMayor(
                        mgi % result.mapWidth, Math.floor(mgi / result.mapWidth));
                    break;
                }
            }
        }

        window._tsoSend('COLLECTIBLES', {
            mapWidth:  result.mapWidth,
            mapHeight: result.mapHeight,
            items:     result.items,
        });
        // setCollectibles already called above; don't call again here

        // ── Pickup detection → calibration anchor ─────────────────────────
        // Compare current collectible set with previous. Exactly one disappearing
        // means a pickup; more disappearing means a zone change or bulk update.
        // We do NOT gate on ctx.maps.length because pickup responses can include
        // zone data (causing the old branch to treat them as zone-loads and skip
        // the diff entirely).
        var currentSet = {};
        result.items.forEach(function(it) { currentSet[it.gridIndex] = it; });

        if (_prevCollectibles !== null && window._TSOOverlay) {
            var missing = Object.keys(_prevCollectibles).filter(function(gi) {
                return !currentSet[gi];
            });
            if (missing.length === 1) {
                window._TSOOverlay.recordPickupCalibPoint(
                    _prevCollectibles[missing[0]].x, _prevCollectibles[missing[0]].y);
            }
        }
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

    // ── XHR interception ────────────────────────────────────────────────
    // The fetch hook captured 30+ AMF responses but none carried the spawn
    // list — possible the game uses XHR for some calls. Hook open() to
    // remember the URL, then on load read the response as ArrayBuffer
    // (works for both responseType='arraybuffer' and binary string text).
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
        this._tsoUrl = url || '';
        return origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
        var xhr = this;
        if (xhr._tsoUrl && xhr._tsoUrl.indexOf('GameServer') >= 0) {
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
})();
"""#

// ─────────────────────────────────────────────────────────────────────────────
// 4. URL rewriter — routes collectible <img> src through the Swift scheme handler
//    so HighlightSchemeHandler can apply a glow effect.
//    Dormant under the Unity client (sprites come from XHR-loaded textures, not
//    individual <img> elements), but retained as a cheap safety net.
// ─────────────────────────────────────────────────────────────────────────────
private let jsURLRewriter = #"""
(function() {
    'use strict';

    var PATTERNS = ['collectible', 'collect_', 'sammelitem', 'pickup_item', 'loot_'];
    var _rewriteCount = 0;

    function shouldRewrite(url) {
        if (!url || !url.startsWith('https://')) return false;
        var lower = url.toLowerCase();
        return PATTERNS.some(function(p) { return lower.includes(p); });
    }

    function rewrite(url) {
        if (!shouldRewrite(url)) return url;
        _rewriteCount++;
        return 'tso-asset' + url.slice(5);
    }

    // Patch HTMLImageElement.prototype.src
    var srcDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    Object.defineProperty(HTMLImageElement.prototype, 'src', {
        set: function(v) { srcDesc.set.call(this, rewrite(v)); },
        get: function()  { return srcDesc.get.call(this); },
        configurable: true,
    });

    // Diagnostic: zero rewrites after 30 s confirms Unity atlas loading
    // (sprites served via XHR, not individual <img> URLs — see jsCollectiblePatcher).
    setTimeout(function() {
        webkit.messageHandlers.logger.postMessage(
            '[URLRewriter] 30-s rewrite count: ' + _rewriteCount +
            (_rewriteCount === 0 ? ' — dormant (expected: Unity uses XHR for textures)' : '')
        );
    }, 30000);
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
