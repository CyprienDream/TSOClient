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

    // Tag an outbound action by the social feature it relates to, by string-
    // matching VO class names. Used so trade/friend/guild outbound calls
    // (whose opcodes are not yet catalogued) land in the logs unconditionally
    // with full body — the user can trigger the in-game action and read the
    // opcode + payload directly off `[Trade:out:…]` / `[Friends:out:…]` /
    // `[Guild:out:…]` lines without enabling diag mode.
    // Circular-safe JSON.stringify. AMF-parsed object graphs reuse references
    // (Flex traits + same-DSId-on-headers), and a bare JSON.stringify on a
    // call with a self-reference throws synchronously, killing whatever
    // outer try/catch swallows it. Replacer substitutes "<circular>" on
    // second encounter, so logging always produces a string.
    function safeStringify(v, maxLen) {
        var seen = [];
        var json;
        try {
            json = JSON.stringify(v, function(_k, val) {
                if (val && typeof val === 'object') {
                    if (seen.indexOf(val) >= 0) return '<circular>';
                    seen.push(val);
                }
                return val;
            }, 2);
        } catch (e) {
            json = '<stringify error: ' + (e && e.message) + '>';
        }
        if (maxLen && json && json.length > maxLen) json = json.slice(0, maxLen);
        return json;
    }

    function classifyOutboundCall(json) {
        if (typeof json !== 'string') return null;
        // Trade: catches TradeWindow VOs *and* private-trade alternatives
        // (Mail/Gift/Donat*/SendResources*/Player2Player/DirectTrade — none
        // confirmed yet, all included so the first capture lands as `[Trade:out]`).
        if (json.indexOf('Trade')              >= 0 ||
            json.indexOf('Mail')               >= 0 ||
            json.indexOf('Gift')               >= 0 ||
            json.indexOf('Donat')              >= 0 ||
            json.indexOf('SendResources')      >= 0 ||
            json.indexOf('Player2Player')      >= 0 ||
            json.indexOf('PlayerToPlayer')     >= 0) return 'Trade';
        if (json.indexOf('Guild.')             >= 0) return 'Guild';
        if (json.indexOf('dPlayerListItemVO')  >= 0 ||
            json.indexOf('dPlayerListVO')      >= 0 ||
            json.indexOf('FriendList')         >= 0) return 'Friends';
        return null;
    }

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
                        if (!call) continue;
                        var callCls = call.__class || '(no __class)';
                        var isServerCall = callCls.indexOf('dServerCall') >= 0;
                        var action = call.data;
                        var actionDataCls = (action && action.data && action.data.__class) || null;
                        // Compact manifest, always on, one line per body item.
                        // Logs *every* class — not just dServerCall — so a
                        // friend-trade VO with a non-standard wrapper class
                        // (dPlayerCall / dTradeCall / dInviteCall …) shows up.
                        webkit.messageHandlers.logger.postMessage(
                            '[AMF3:out:call:' + channel + '] cls=' + callCls.split('.').pop() +
                            (isServerCall
                                ? (' callType=' + call.type +
                                   ' actionType=' + (action && action.type) +
                                   ' actionGrid=' + (action && action.grid) +
                                   ' actionEndGrid=' + (action && action.endGrid) +
                                   ' dataCls=' + actionDataCls)
                                : (' keys=' + Object.keys(call).filter(function(k){return k!=='__class';}).join(','))));
                        // Full body dump FIRST — ungated, circular-safe, auth
                        // redacted. Done before any other per-call logging so
                        // a downstream exception can't suppress it. This is
                        // the recon log that matters for opcode discovery.
                        try {
                            var redacted = {};
                            for (var rk in call) if (call.hasOwnProperty(rk)) redacted[rk] = call[rk];
                            if (redacted.dsoAuthToken)          redacted.dsoAuthToken          = '<r>';
                            if (redacted.dsoAuthRandomClientID) redacted.dsoAuthRandomClientID = '<r>';
                            if (redacted.dsoAuthUser)           redacted.dsoAuthUser           = '<r>';
                            webkit.messageHandlers.logger.postMessage(
                                '[AMF3:out:call:' + channel + ':full] cls=' + callCls +
                                (isServerCall ? ' callType=' + call.type : '') +
                                ' body=' + safeStringify(redacted, 6000));
                        } catch (_) {}

                        if (!isServerCall) continue;

                        try {
                            window._tsoDiagLog(
                                '[AMF3:out:' + channel + '] callType=' + call.type +
                                ' zoneID=' + call.zoneID +
                                ' actionType=' + (action && action.type) +
                                ' actionGrid=' + (action && action.grid) +
                                ' data=' + safeStringify(action && action.data, 800));
                        } catch (_) {}

                        // Trade / friend / guild outbound — ungated, full body.
                        // Tries the inner action.data first, falls back to the
                        // whole action so we still see Trade-related calls
                        // whose payload sits at unexpected nesting depths.
                        try {
                            var innerJson = safeStringify(action && action.data, 0);
                            var tag = classifyOutboundCall(innerJson);
                            if (!tag) {
                                var actionJson = safeStringify(action, 0);
                                tag = classifyOutboundCall(actionJson);
                                if (tag) innerJson = actionJson;
                            }
                            if (tag) {
                                webkit.messageHandlers.logger.postMessage(
                                    '[' + tag + ':out:' + channel + '] callType=' + call.type +
                                    ' zoneID=' + call.zoneID +
                                    ' actionType=' + (action && action.type) +
                                    ' actionGrid=' + (action && action.grid) +
                                    ' actionEndGrid=' + (action && action.endGrid) +
                                    ' payload=' + (innerJson || '').slice(0, 6000));
                            }
                        } catch (_) {}
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

    // Chat traffic (r03-chat…/http-bind/) is XMPP-over-BOSH (XML), NOT AMF.
    // The previous behaviour was to throw it at the AMF parser and log
    // "Out of bounds access" per request, drowning the console. Detect by
    // URL substring and route XMPP bodies to a plain-text logger so we can
    // see private-trade invites / chat messages.
    function isChatUrl(url) {
        return typeof url === 'string' && url.indexOf('/http-bind') >= 0;
    }

    // Compact body type + size descriptor — used by the unconditional
    // "every POST" logger so we can see *all* outbound traffic shapes,
    // not just AMF. A non-AMF private-trade endpoint (JSON, form-encoded,
    // protobuf) would otherwise be invisible to the AMF-only path.
    function bodyTypeStr(b) {
        if (b == null) return 'null';
        if (b instanceof ArrayBuffer)      return 'ArrayBuffer';
        if (b instanceof Uint8Array)       return 'Uint8Array';
        if (b instanceof Blob)             return 'Blob<' + (b.type || '?') + '>';
        if (typeof b === 'string')         return 'string';
        if (typeof FormData       !== 'undefined' && b instanceof FormData)       return 'FormData';
        if (typeof URLSearchParams!== 'undefined' && b instanceof URLSearchParams)return 'URLSearchParams';
        return typeof b;
    }
    function bodyLen(b) {
        if (b == null) return 0;
        if (b instanceof ArrayBuffer)      return b.byteLength;
        if (b instanceof Uint8Array)       return b.byteLength;
        if (b instanceof Blob)             return b.size;
        if (typeof b === 'string')         return b.length;
        return -1;
    }
    // Best-effort text preview of a non-AMF body for trade reconnaissance.
    // Returns a promise so async bodies (Blob) don't block the call site.
    function bodyPreview(b) {
        if (typeof b === 'string') return Promise.resolve(b.slice(0, 1500));
        if (b instanceof ArrayBuffer || b instanceof Uint8Array) {
            try {
                var u8 = b instanceof ArrayBuffer ? new Uint8Array(b) : b;
                return Promise.resolve(new TextDecoder('utf-8', {fatal: false}).decode(u8).slice(0, 1500));
            } catch (_) { return Promise.resolve(''); }
        }
        if (b instanceof Blob) return b.text().then(function(t) { return t.slice(0, 1500); }).catch(function(){ return ''; });
        if (typeof URLSearchParams !== 'undefined' && b instanceof URLSearchParams) return Promise.resolve(b.toString().slice(0, 1500));
        return Promise.resolve('');
    }

    function logChatBody(text, direction, url) {
        if (typeof text !== 'string' || text.length === 0) return;
        // Anything potentially trade-related — be generous, this is one-shot
        // recon. A "trade", "offer", "barter", "resource" mention is enough.
        var lower = text.toLowerCase();
        var tradeHint = lower.indexOf('trade')  >= 0 ||
                        lower.indexOf('offer')  >= 0 ||
                        lower.indexOf('barter') >= 0 ||
                        lower.indexOf('gift')   >= 0 ||
                        lower.indexOf('mail')   >= 0;
        var tag = tradeHint ? 'Trade:chat' : 'XMPP';
        webkit.messageHandlers.logger.postMessage(
            '[' + tag + ':' + direction + '] ' + (url || '').slice(0, 80) +
            ' bytes=' + text.length +
            ' body=' + text.slice(0, 4000)
        );
    }

    // Parses outbound AMF envelopes to refresh auth context and learn specialist types.
    function captureOutboundBody(body, channel, url) {
        if (isChatUrl(url)) {
            // Plain-text XMPP/BOSH path.
            if (typeof body === 'string') { logChatBody(body, 'out', url); return; }
            if (body instanceof Blob) {
                body.text().then(function(t) { logChatBody(t, 'out', url); }).catch(function(){});
                return;
            }
            if (body instanceof ArrayBuffer || body instanceof Uint8Array) {
                var u8 = (body instanceof ArrayBuffer) ? new Uint8Array(body) : body;
                try { logChatBody(new TextDecoder('utf-8').decode(u8), 'out', url); } catch (_) {}
                return;
            }
            return;
        }
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
            captureOutboundBody(init.body, 'fetch', url);
            window._tsoDiagLog('[AMF3:out:url] POST ' + url.slice(0, 120));
            // Unconditional, ungated: every non-chat POST URL + body shape.
            // Chat is already captured separately by captureOutboundBody.
            if (!isChatUrl(url)) {
                webkit.messageHandlers.logger.postMessage(
                    '[Net:out:fetch] POST ' + url.slice(0, 160) +
                    ' bodyType=' + bodyTypeStr(init.body) +
                    ' bodyLen=' + bodyLen(init.body));
                // If body isn't AMF-typed binary, dump a preview so a JSON /
                // form-encoded private-trade endpoint reveals itself.
                var isBinary = init.body instanceof ArrayBuffer ||
                               init.body instanceof Uint8Array  ||
                               (init.body instanceof Blob && /amf|octet/.test(init.body.type || ''));
                if (!isBinary) {
                    bodyPreview(init.body).then(function(preview) {
                        if (preview) {
                            webkit.messageHandlers.logger.postMessage(
                                '[Net:out:fetch:body] ' + url.slice(0, 120) +
                                ' preview=' + preview);
                        }
                    });
                }
            }
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
            // Chat / XMPP responses: server pushes presence, chat, and
            // potentially private-trade invites in the BOSH response body.
            if (isChatUrl(url)) {
                response.clone().text().then(function(text) {
                    logChatBody(text, 'in', url);
                }).catch(function(){});
                return response;
            }
            var wantAMF = url.includes('GameServer') ||
                          ct.includes('amf') ||
                          ct.includes('octet-stream');
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
            captureOutboundBody(body, 'xhr', xhr._tsoUrl);
            window._tsoDiagLog('[AMF3:out:url] XHR POST ' + (xhr._tsoUrl || '?').slice(0, 120));
            if (!isChatUrl(xhr._tsoUrl)) {
                webkit.messageHandlers.logger.postMessage(
                    '[Net:out:xhr] POST ' + (xhr._tsoUrl || '?').slice(0, 160) +
                    ' bodyType=' + bodyTypeStr(body) +
                    ' bodyLen=' + bodyLen(body));
                var isBinary = body instanceof ArrayBuffer ||
                               body instanceof Uint8Array  ||
                               (body instanceof Blob && /amf|octet/.test(body.type || ''));
                if (!isBinary) {
                    bodyPreview(body).then(function(preview) {
                        if (preview) {
                            webkit.messageHandlers.logger.postMessage(
                                '[Net:out:xhr:body] ' + (xhr._tsoUrl || '?').slice(0, 120) +
                                ' preview=' + preview);
                        }
                    });
                }
            }
        }
        if (isChatUrl(xhr._tsoUrl)) {
            xhr.addEventListener('load', function() {
                try {
                    var t = (typeof xhr.responseText === 'string') ? xhr.responseText : '';
                    if (t) logChatBody(t, 'in', xhr._tsoUrl);
                } catch (_) {}
            });
            return origSend.apply(this, arguments);
        }
        var wantResponse = xhr._tsoUrl && (
            xhr._tsoUrl.indexOf('GameServer') >= 0 ||
            xhr._tsoUrl.indexOf('amf') >= 0
        );
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

    // ── WebSocket interception ──────────────────────────────────────────
    // The fetch + XHR hooks cover all HTTP traffic, but a private-trade
    // request that travels over a real-time WebSocket (XMPP-WS, custom
    // game socket) would slip past entirely. Wrap the constructor so every
    // new WebSocket reports its URL, outbound frames, and inbound frames.
    var OrigWS = window.WebSocket;
    if (OrigWS && !window._tsoWSHooked) {
        function WrappedWS(url, protocols) {
            webkit.messageHandlers.logger.postMessage(
                '[WS:open] ' + (url || '?').slice(0, 160) +
                ' protocols=' + (protocols ? JSON.stringify(protocols) : 'none'));
            var ws = (protocols !== undefined) ? new OrigWS(url, protocols) : new OrigWS(url);
            var origWsSend = ws.send.bind(ws);
            ws.send = function(data) {
                try {
                    var info = bodyTypeStr(data) + '/' + bodyLen(data);
                    if (typeof data === 'string') {
                        webkit.messageHandlers.logger.postMessage(
                            '[WS:out] ' + info + ' ' + data.slice(0, 1500));
                    } else {
                        bodyPreview(data).then(function(p) {
                            webkit.messageHandlers.logger.postMessage(
                                '[WS:out] ' + info + (p ? ' ' + p : ''));
                        });
                    }
                } catch (_) {}
                return origWsSend(data);
            };
            ws.addEventListener('message', function(ev) {
                try {
                    var data = ev.data;
                    var info = bodyTypeStr(data) + '/' + bodyLen(data);
                    if (typeof data === 'string') {
                        webkit.messageHandlers.logger.postMessage(
                            '[WS:in] ' + info + ' ' + data.slice(0, 1500));
                    } else {
                        bodyPreview(data).then(function(p) {
                            webkit.messageHandlers.logger.postMessage(
                                '[WS:in] ' + info + (p ? ' ' + p : ''));
                        });
                    }
                } catch (_) {}
            });
            return ws;
        }
        WrappedWS.prototype  = OrigWS.prototype;
        WrappedWS.CONNECTING = OrigWS.CONNECTING;
        WrappedWS.OPEN       = OrigWS.OPEN;
        WrappedWS.CLOSING    = OrigWS.CLOSING;
        WrappedWS.CLOSED     = OrigWS.CLOSED;
        window.WebSocket = WrappedWS;
        window._tsoWSHooked = true;
        webkit.messageHandlers.logger.postMessage('[WS] hook installed');
    }
})();
