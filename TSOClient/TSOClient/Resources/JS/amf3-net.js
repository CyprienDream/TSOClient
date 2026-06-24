(function() {
    'use strict';

    // Net interceptor: wraps fetch() and XMLHttpRequest so we can sniff inbound
    // GameServer responses (handed to the scanner) and outbound POST bodies
    // (used to refresh auth context and learn specialist types).
    //
    // Depends on:
    //   window._TSOAMFParser  (amf3-parser.js)
    //   window._tsoClassifier (amf3-classifier.js)
    //   window._tsoScanner    (amf3-scanner.js)
    //
    // INVARIANT: must run BEFORE collectible-patcher.js so the patcher wraps
    // this file's wrapped fetch; otherwise AMF3 parsing on non-collectible
    // URLs breaks. See CLAUDE.md "Key invariants".

    var AMFParser  = window._TSOAMFParser;
    var classifier = window._tsoClassifier;
    var scanner    = window._tsoScanner;

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
                        window._tsoDiagLog(
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

    // Parses outbound AMF envelopes to refresh auth context and learn specialist types.
    function captureOutboundBody(body, channel) {
        function processBuf(buf) {
            try {
                var p = new AMFParser(buf);
                var bodies = p.parseEnvelope();
                cacheAuthCtx(bodies);
                classifier.learnFromOutbound(bodies);
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

    // ── Fetch interception ──────────────────────────────────────────────
    var origFetch = window.fetch;
    window.fetch = function(input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';

        var isPost = init && (init.method || '').toUpperCase() === 'POST';
        if (isPost && init.body) {
            // Capture all POSTs — buff and other actions may use different URLs.
            captureOutboundBody(init.body, 'fetch');
            window._tsoDiagLog('[AMF3:out:url] POST ' + url.slice(0, 120));
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
            // Narrow the AMF trigger: only the GameServer/amf endpoint plus
            // explicit "amf" content-types qualify. The previous filter caught
            // any URL with "GameServer" and any "octet-stream" response, which
            // forced response.clone() + arrayBuffer() materialization on lots
            // of unrelated assets — measurable memory churn over a long
            // session.
            var wantAMF = url.indexOf('GameServer/amf') >= 0 || ct.indexOf('amf') >= 0;
            if (wantAMF) {
                response.clone().arrayBuffer().then(function(buf) {
                    if (buf.byteLength > 3) scanner.analyzeAMFBuffer(buf, 'fetch');
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
            window._tsoDiagLog('[AMF3:out:url] XHR POST ' + (xhr._tsoUrl || '?').slice(0, 120));
        }
        // Match the fetch path: only the AMF endpoint, not every GameServer URL.
        var wantResponse = xhr._tsoUrl && xhr._tsoUrl.indexOf('GameServer/amf') >= 0;
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
                    if (buf) scanner.analyzeAMFBuffer(buf, 'xhr');
                } catch (e) {
                    webkit.messageHandlers.logger.postMessage('[AMF3:xhr] handler error: ' + e);
                }
            });
        }
        return origSend.apply(this, arguments);
    };
})();
