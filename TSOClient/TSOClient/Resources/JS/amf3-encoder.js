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

    var _counterOffset = 0;  // increments each dispatch to stay distinct within a session

    function nextCounter() {
        _counterOffset++;
        // Mirror the game's sequence: game's last known counter + our own offset.
        // Falls back to 1000+ if no game requests seen yet.
        var base = window._tsoLastSeq || 999;
        return base + _counterOffset;
    }

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
        var seq = nextCounter();
        w.envelope('null', '/' + seq, argsArray);
        var buf = w.toBuffer();
        webkit.messageHandlers.logger.postMessage('[AMF3:rpc] POST seq=/' + seq + ' url=' + url.slice(0, 120) + ' bytes=' + buf.byteLength);
        return fetch(url, {
            method: 'POST',
            credentials: 'omit',
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
            type:     (opts.actionType !== undefined ? opts.actionType : 0) | 0,
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
            '[_TSORPC] dispatch uid=' + uid1 + ':' + uid2 +
            ' actionType=' + action.type + ' subTaskID=' + subTaskID +
            ' zone=' + ctx.zoneID + ' DSId=' + (ctx.DSId || '?').slice(0, 16) +
            ' clientID=' + ctx.dsoAuthRandomClientID +
            ' url=' + (getRealmUrl() || '?').slice(0, 80));

        // Mark this as our own dispatch so learnSpecialistTypes skips it.
        window._tsoOwnDispatch = uid1 + ':' + uid2;
        return sendAMF([msg]).then(function(r) {
            window._tsoOwnDispatch = null;
            return r;
        }, function(e) {
            window._tsoOwnDispatch = null;
            return Promise.reject(e);
        }).then(function(result) {
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

})();
