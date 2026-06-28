import { describe, it, expect } from 'vitest';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const THIS_DIR = path.dirname(fileURLToPath(import.meta.url));
const JS_DIR   = path.resolve(THIS_DIR, '../TSOClient/TSOClient/Resources/JS');

// Build a fresh sandbox loaded with amf3-scanner.js. The parser is a
// programmable stub: each `analyze(...)` call sets `state.nextBodies` and the
// FakeParser returns it from parseEnvelope. The classifier methods are no-op
// stubs; we only care about which bridge messages the scanner emits.
function buildScannerSandbox() {
    const sends = [];
    const state = { nextBodies: [] };

    function FakeParser() {}
    FakeParser.prototype.parseEnvelope = function() { return state.nextBodies; };
    FakeParser.prototype.amf3Val      = function() { return null; };

    const sandbox = {
        window: {
            _TSOAMFParser: FakeParser,
            _tsoClassifier: {
                classifyFromTask: () => null,
                classifySpec:     () => 'explorer',
                subtypeNameFor:   () => null,
            },
            _tsoSend:     (type, payload) => sends.push({ type, payload }),
            _tsoDiagLog:  () => {},
        },
        console,
        TextEncoder, TextDecoder,
        ArrayBuffer, Uint8Array, Date, WeakSet, Promise,
        webkit: { messageHandlers: { logger: { postMessage: () => {} } } },
    };
    vm.createContext(sandbox);
    const src = fs.readFileSync(path.join(JS_DIR, 'amf3-scanner.js'), 'utf8');
    vm.runInContext(src, sandbox, { filename: 'amf3-scanner.js' });

    return {
        sandbox,
        sends,
        analyze(bodies) {
            state.nextBodies = bodies;
            sandbox.window._tsoScanner.analyzeAMFBuffer(new ArrayBuffer(8), 'fetch');
        },
        specialistsCount() {
            return sends.filter((s) => s.type === 'SPECIALISTS').length;
        },
    };
}

// ── VO builders ─────────────────────────────────────────────────────────────
const FQN = (cls) => 'defaultGame.Communication.VO.' + cls;

function zoneVO({ owner, visitor, adventureName = null, mapWidth = 89, mapHeight = 196 }) {
    return {
        __class: FQN('dZoneVO'),
        mapWidth,
        mapHeight,
        zoneOwnerPlayerID:   owner,
        zoneVisitorPlayerID: visitor,
        adventureName,
    };
}

function specVO({ uid1 = 1, uid2 = 2, name = 'Hans' }) {
    return {
        __class: FQN('dSpecialistVO'),
        uniqueID: { uniqueID1: uid1, uniqueID2: uid2 },
        name_string: name,
        specialistType: 1,
        garrisonBuildingGridPos: -1,
        task: null,
        skills: { __class: 'flex.messaging.io.ArrayCollection', source: [] },
    };
}

// Stand-in dBuildingVO carrying a buildingGrid — only used to defeat the
// "no game-world data" early-skip on incremental updates that have no dZoneVO.
function buildingVO({ grid = 100 } = {}) {
    return {
        __class: FQN('dBuildingVO'),
        buildingGrid: grid,
        skin: 'Warehouse',
    };
}

function envelope(...nodes) {
    return [{ value: nodes }];
}

describe('amf3-scanner home-zone gate', () => {
    it('emits SPECIALISTS on a home zone-load (owner == visitor, no adventure)', () => {
        const s = buildScannerSandbox();
        s.analyze(envelope(zoneVO({ owner: 1, visitor: 1 }), specVO({})));
        expect(s.specialistsCount()).toBe(1);
    });

    it('suppresses SPECIALISTS on a friend zone-load (owner != visitor)', () => {
        const s = buildScannerSandbox();
        s.analyze(envelope(zoneVO({ owner: 2, visitor: 1 }), specVO({})));
        expect(s.specialistsCount()).toBe(0);
    });

    it('suppresses SPECIALISTS on an adventure zone (adventureName set)', () => {
        const s = buildScannerSandbox();
        s.analyze(envelope(
            zoneVO({ owner: 1, visitor: 1, adventureName: 'TheBlackKnights' }),
            specVO({})
        ));
        expect(s.specialistsCount()).toBe(0);
    });

    it('keeps suppressing while away — incremental updates without dZoneVO inherit sticky off-home state', () => {
        const s = buildScannerSandbox();
        // First: enter friend's island. Gate flips to off-home.
        s.analyze(envelope(zoneVO({ owner: 2, visitor: 1 }), specVO({})));
        // Then: an incremental update (no dZoneVO) — building included only
        // to defeat the "no game-world data" early-skip, so the gate runs.
        s.analyze(envelope(buildingVO(), specVO({ uid1: 3, uid2: 4 })));
        expect(s.specialistsCount()).toBe(0);
    });

    it('keeps allowing while home — incremental updates without dZoneVO inherit sticky on-home state', () => {
        const s = buildScannerSandbox();
        s.analyze(envelope(zoneVO({ owner: 1, visitor: 1 }), specVO({})));
        s.analyze(envelope(buildingVO(), specVO({ uid1: 3, uid2: 4 })));
        expect(s.specialistsCount()).toBe(2);
    });

    it('reopens the gate when the player returns home from a friend', () => {
        const s = buildScannerSandbox();
        s.analyze(envelope(zoneVO({ owner: 1, visitor: 1 }), specVO({})));  // home
        s.analyze(envelope(zoneVO({ owner: 2, visitor: 1 }), specVO({})));  // visit friend
        s.analyze(envelope(zoneVO({ owner: 1, visitor: 1 }), specVO({})));  // return home
        // Three calls, only the friend-visit one was suppressed.
        expect(s.specialistsCount()).toBe(2);
    });

    it('does not gate on auth-ctx zoneID — friend response is blocked even when _tsoAuthCtx still reads home', () => {
        // Precise regression: the game's "visit friend" outbound carries the
        // home zoneID, so _tsoAuthCtx.zoneID still reads home when the
        // friend-zone inbound lands. The pre-fix gate cached the home zoneID
        // on the first home observation and then trusted auth-ctx, which let
        // the friend payload through and corrupted the panel + auto-loop.
        const s = buildScannerSandbox();
        // Auth-ctx is set BEFORE the first home call — that's what the
        // pre-fix gate would have cached as `_homeZoneID`, then re-used for
        // subsequent payloads via `currentAuthZoneID() === _homeZoneID`.
        s.sandbox.window._tsoAuthCtx = { zoneID: 1234 };
        s.analyze(envelope(zoneVO({ owner: 1, visitor: 1 }), specVO({})));   // home — pre-fix caches 1234
        // Auth-ctx stays at 1234 (visit-friend outbound never updated it),
        // so the pre-fix gate's `1234 === 1234` check passes and admits the
        // friend payload. The new gate reads owner!=visitor from dZoneVO
        // and rejects it.
        s.analyze(envelope(zoneVO({ owner: 2, visitor: 1 }), specVO({})));   // friend
        expect(s.specialistsCount()).toBe(1);
    });
});
