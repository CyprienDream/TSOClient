(function() {
    'use strict';

    var HASHES = new Set(/*__HASHES__*/[]);

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
