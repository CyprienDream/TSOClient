(function() {
    'use strict';

    // AMF0/AMF3 binary deserializer. Used by the scanner to read inbound
    // GameServer responses and by the encoder to parse RPC acks.
    //
    // Public surface: window._TSOAMFParser (constructor). Construct with an
    // ArrayBuffer and call .parseEnvelope() for full AMF0 envelopes or
    // .amf3Val() for a bare AMF3 value.

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

    window._TSOAMFParser = AMFParser;
})();
