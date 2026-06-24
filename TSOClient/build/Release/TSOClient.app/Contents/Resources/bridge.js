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
