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
