import { describe, it, expect, beforeEach } from 'vitest';
import { createAMFSandbox, loadModule } from './loadModule.js';

// Roundtrip coverage for the AMF3 parser using the encoder as a byte producer.
// If either side drifts, these go red.
describe('AMF3 parser ←→ encoder roundtrip', () => {
    let sandbox;

    beforeEach(() => {
        sandbox = createAMFSandbox();
        loadModule(sandbox, 'amf3-parser');
        loadModule(sandbox, 'amf3-encoder');
    });

    function roundtrip(value) {
        const w = new sandbox.window._TSOAMFWriter();
        w.amf3Val(value);
        const p = new sandbox.window._TSOAMFParser(w.toBuffer());
        return p.amf3Val();
    }

    it('roundtrips null / undefined / booleans', () => {
        expect(roundtrip(null)).toBeNull();
        expect(roundtrip(undefined)).toBeUndefined();
        expect(roundtrip(true)).toBe(true);
        expect(roundtrip(false)).toBe(false);
    });

    it('roundtrips integers across the u29 size boundaries', () => {
        // u29 picks 1/2/3/4-byte encoding by magnitude — exercise each.
        for (const n of [0, 1, 0x7f, 0x80, 0x3fff, 0x4000, 0x1fffff, 0x200000, 0xfffffff]) {
            expect(roundtrip(n)).toBe(n);
        }
    });

    it('roundtrips a negative integer via two-complement u29', () => {
        // -1 → 0x1fffffff in u29; encoder/parser must agree on the wrap.
        expect(roundtrip(-1)).toBe(-1);
        expect(roundtrip(-100000)).toBe(-100000);
    });

    it('roundtrips doubles', () => {
        expect(roundtrip(3.14)).toBeCloseTo(3.14);
        expect(roundtrip(1e20)).toBe(1e20);
    });

    it('roundtrips strings (empty, ASCII, multibyte)', () => {
        expect(roundtrip('')).toBe('');
        expect(roundtrip('hello')).toBe('hello');
        expect(roundtrip('héllo 🌍')).toBe('héllo 🌍');
    });

    it('roundtrips arrays preserving order and element types', () => {
        const arr = [1, 'two', null, true, 3.14];
        expect(roundtrip(arr)).toEqual(arr);
    });

    it('roundtrips a typed object and preserves member order on the wire', () => {
        const o = { __class: 'test.VO.Thing', a: 1, b: 'two', c: null };
        const out = roundtrip(o);
        // Parser injects __class first, then walks traits.m in order.
        expect(Object.keys(out)).toEqual(['__class', 'a', 'b', 'c']);
        expect(out.__class).toBe('test.VO.Thing');
        expect(out.a).toBe(1);
        expect(out.b).toBe('two');
        expect(out.c).toBeNull();
    });

    it('roundtrips a string reference: same value encoded twice uses the table', () => {
        // The reference table is only triggered when the same string appears
        // twice in the same message — assert that the second occurrence is
        // still readable after table substitution.
        const o = { __class: 'test.VO.Pair', x: 'shared', y: 'shared' };
        const out = roundtrip(o);
        expect(out.x).toBe('shared');
        expect(out.y).toBe('shared');
    });
});

describe('AMF0 envelope', () => {
    let sandbox;
    beforeEach(() => {
        sandbox = createAMFSandbox();
        loadModule(sandbox, 'amf3-parser');
        loadModule(sandbox, 'amf3-encoder');
    });

    it('roundtrips target, response, and an AMF3-typed body', () => {
        const w = new sandbox.window._TSOAMFWriter();
        w.envelope('null', '/7', ['ping', 42]);

        const p = new sandbox.window._TSOAMFParser(w.toBuffer());
        const bodies = p.parseEnvelope();

        expect(bodies).toHaveLength(1);
        expect(bodies[0].target).toBe('null');
        expect(bodies[0].response).toBe('/7');
        expect(bodies[0].value).toEqual(['ping', 42]);
    });
});
