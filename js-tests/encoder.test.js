import { describe, it, expect, beforeEach } from 'vitest';
import { createAMFSandbox, loadModule } from './loadModule.js';

// AMF3 trait member order is load-bearing on the wire — a silent reorder by
// an editor breaks the GameServer protocol. These tests pin the byte-level
// shape of every outbound dispatch by sending one through a stubbed `fetch`,
// then parsing the captured body and asserting member sequences.
//
// `Object.keys(parsedObj)` mirrors `traits.m` order (after __class), so
// asserting on Object.keys() is the same as asserting on the on-wire trait
// member array.

describe('outbound RPC wire format', () => {
    let sandbox;
    let captured;       // ArrayBuffer captured by stub fetch

    beforeEach(() => {
        sandbox = createAMFSandbox();
        loadModule(sandbox, 'amf3-parser');
        loadModule(sandbox, 'amf3-encoder');

        // Deterministic auth context so RemotingMessage fields aren't random.
        sandbox.window._tsoAuthCtx = {
            dsoAuthUser:            'tester',
            dsoAuthToken:           'tok',
            dsoAuthRandomClientID:  42,
            zoneID:                 100,
            DSId:                   'session-uuid',
        };
        sandbox.window._tsoRealmUrl = 'https://test.invalid/GameServer/amf';
        // sendAMF's nextCounter does base+offset; base=window._tsoLastSeq||999.
        // Leaving _tsoLastSeq unset exercises the "no game request observed
        // yet" fallback (base=999); first call returns /1000.

        captured = null;
        sandbox.fetch = (_url, opts) => {
            captured = opts.body;
            // Empty buffer — parseEnvelope inside sendAMF swallows the throw.
            return Promise.resolve({
                arrayBuffer: () => Promise.resolve(new ArrayBuffer(0)),
            });
        };
    });

    function parseCapturedCall() {
        expect(captured, 'fetch was not called').not.toBeNull();
        const p = new sandbox.window._TSOAMFParser(captured);
        const bodies = p.parseEnvelope();
        expect(bodies).toHaveLength(1);
        return { envelope: bodies[0], rmsg: bodies[0].value[0] };
    }

    it('dispatchSpecialist: envelope target="null", response mirrors counter', async () => {
        await sandbox.window._TSORPC.dispatchSpecialist({
            uid1: 5, uid2: 7, actionType: 1, taskCode: 3, targetGrid: 0,
        });
        const { envelope } = parseCapturedCall();
        expect(envelope.target).toBe('null');
        // First call after a freshly loaded module: base=999, offset=1 → "/1000".
        expect(envelope.response).toBe('/1000');
    });

    it('dispatchSpecialist: RemotingMessage has the 13 members in canonical order', async () => {
        await sandbox.window._TSORPC.dispatchSpecialist({
            uid1: 5, uid2: 7, actionType: 1, taskCode: 3, targetGrid: 0,
        });
        const { rmsg } = parseCapturedCall();
        expect(rmsg.__class).toBe('flex.messaging.messages.RemotingMessage');
        expect(Object.keys(rmsg)).toEqual([
            '__class',
            'source', 'operation', 'parameters', 'remoteUsername', 'remotePassword',
            'correlationId', 'body', 'clientId', 'destination', 'headers',
            'messageId', 'timestamp', 'timeToLive',
        ]);
        expect(rmsg.source).toBe('com.bluebyte.game.servlet.EventHandler');
        expect(rmsg.operation).toBe('ExecuteServerCall');
        expect(rmsg.destination).toBe('SMC');
        expect(rmsg.timestamp).toBe(0);
        expect(rmsg.timeToLive).toBe(0);
    });

    it('dispatchSpecialist: dServerCall has 6 members in canonical order, type=95', async () => {
        await sandbox.window._TSORPC.dispatchSpecialist({
            uid1: 5, uid2: 7, actionType: 1, taskCode: 3, targetGrid: 0,
        });
        const { rmsg } = parseCapturedCall();
        const call = rmsg.body[0];
        expect(call.__class).toBe('defaultGame.Communication.VO.dServerCall');
        expect(Object.keys(call)).toEqual([
            '__class',
            'type', 'zoneID', 'data', 'dsoAuthUser', 'dsoAuthToken', 'dsoAuthRandomClientID',
        ]);
        expect(call.type).toBe(95);
        expect(call.zoneID).toBe(100);
        expect(call.dsoAuthUser).toBe('tester');
        expect(call.dsoAuthToken).toBe('tok');
        expect(call.dsoAuthRandomClientID).toBe(42);
    });

    it('dispatchSpecialist: dServerAction has 4 members in canonical order', async () => {
        await sandbox.window._TSORPC.dispatchSpecialist({
            uid1: 5, uid2: 7, actionType: 1, taskCode: 3, targetGrid: 11,
        });
        const { rmsg } = parseCapturedCall();
        const action = rmsg.body[0].data;
        expect(action.__class).toBe('defaultGame.Communication.VO.dServerAction');
        expect(Object.keys(action)).toEqual(['__class', 'type', 'grid', 'endGrid', 'data']);
        expect(action.type).toBe(1);
        expect(action.grid).toBe(11);
        expect(action.endGrid).toBe(0);
    });

    it('dispatchSpecialist: dStartSpecialistTaskVO has 3 members, paramString=null', async () => {
        await sandbox.window._TSORPC.dispatchSpecialist({
            uid1: 5, uid2: 7, actionType: 1, taskCode: 3, targetGrid: 0,
        });
        const { rmsg } = parseCapturedCall();
        const task = rmsg.body[0].data.data;
        expect(task.__class).toBe('defaultGame.Communication.VO.dStartSpecialistTaskVO');
        expect(Object.keys(task)).toEqual(['__class', 'uniqueID', 'subTaskID', 'paramString']);
        expect(task.subTaskID).toBe(3);
        expect(task.paramString).toBeNull();
    });

    it('dispatchSpecialist: dUniqueID member order is [uniqueID1, uniqueID2]', async () => {
        await sandbox.window._TSORPC.dispatchSpecialist({
            uid1: 5, uid2: 7, actionType: 1, taskCode: 3, targetGrid: 0,
        });
        const { rmsg } = parseCapturedCall();
        const uid = rmsg.body[0].data.data.uniqueID;
        expect(uid.__class).toBe('defaultGame.Communication.VO.dUniqueID');
        expect(Object.keys(uid)).toEqual(['__class', 'uniqueID1', 'uniqueID2']);
        expect(uid.uniqueID1).toBe(5);
        expect(uid.uniqueID2).toBe(7);
    });

    it('dispatchBuff: dServerCall.type=61, action.data is a bare dUniqueID', async () => {
        await sandbox.window._TSORPC.dispatchBuff({
            buffUid1: 100, buffUid2: 200, targetGrid: 33,
        });
        const { rmsg } = parseCapturedCall();
        const call   = rmsg.body[0];
        const action = call.data;

        expect(call.type).toBe(61);
        expect(Object.keys(action)).toEqual(['__class', 'type', 'grid', 'endGrid', 'data']);
        expect(action.type).toBe(0);
        expect(action.grid).toBe(33);
        expect(action.endGrid).toBe(0);

        const buffID = action.data;
        expect(buffID.__class).toBe('defaultGame.Communication.VO.dUniqueID');
        expect(Object.keys(buffID)).toEqual(['__class', 'uniqueID1', 'uniqueID2']);
        expect(buffID.uniqueID1).toBe(100);
        expect(buffID.uniqueID2).toBe(200);
    });

    it('dispatchTrade: dServerCall.type=1049, call.data is dTradeOfferVO directly (no dServerAction wrapper)', async () => {
        await sandbox.window._TSORPC.dispatchTrade({
            receipientId:   8888,
            offerResource: 'WoodResource',
            offerAmount:    100,
            costsResource: 'StoneResource',
            costsAmount:    50,
            slotPos:        3,
        });
        const { rmsg } = parseCapturedCall();
        const call  = rmsg.body[0];
        const trade = call.data;

        expect(call.type).toBe(1049);
        expect(trade.__class).toBe('defaultGame.Communication.VO.dTradeOfferVO');
        // Member order preserves the on-the-wire `receipientId` typo.
        expect(Object.keys(trade)).toEqual([
            '__class',
            'receipientId', 'offerRes', 'offerBuff',
            'costsRes', 'costsBuff', 'lots', 'slotType', 'slotPos',
        ]);
        expect(trade.receipientId).toBe(8888);
        expect(trade.offerBuff).toBeNull();
        expect(trade.costsBuff).toBeNull();
        expect(trade.lots).toBe(0);
        expect(trade.slotType).toBe(4);   // private-trade default
        expect(trade.slotPos).toBe(3);

        // dResourceVO member order: name_string, amount, producedAmount.
        expect(Object.keys(trade.offerRes)).toEqual(
            ['__class', 'name_string', 'amount', 'producedAmount']);
        expect(trade.offerRes.name_string).toBe('WoodResource');
        expect(trade.offerRes.amount).toBe(100);
        expect(trade.costsRes.name_string).toBe('StoneResource');
        expect(trade.costsRes.amount).toBe(50);
    });

    it('dispatchTrade (public): auto-picks lowest unused slotPos from _tsoOwnPublicTradeSlots', async () => {
        // Simulate a 1062 snapshot: two of our own public trades already
        // occupy slotType=2 at positions 0 and 1. The third dispatch must
        // land at slotPos=2, not 0. Same-slot re-use is what caused the
        // "only first trade posts" bug — server silently drops duplicates.
        sandbox.window._tsoOwnPublicTradeSlots = { 2: { 0: true, 1: true } };
        await sandbox.window._TSORPC.dispatchTrade({
            receipientId:   0,
            offerResource: 'Wood',
            offerAmount:    1,
            costsResource: 'EMEventResource',
            costsAmount:    5,
            lots:           1,
            slotType:       2,
            // no slotPos → encoder must pick 2.
        });
        const { rmsg } = parseCapturedCall();
        const trade = rmsg.body[0].data;
        expect(trade.slotType).toBe(2);
        expect(trade.slotPos).toBe(2);
        // Optimistic claim: 2 is now recorded so the next dispatch picks 3.
        expect(sandbox.window._tsoOwnPublicTradeSlots[2][2]).toBe(true);
    });

    it('dispatchTrade (public): auto-picks 0 when the slot map is empty', async () => {
        // Fresh session, no 1062 seen yet — auto-pick must fall back to 0
        // (the free first slot) rather than crash on a missing map.
        await sandbox.window._TSORPC.dispatchTrade({
            receipientId:   0,
            offerResource: 'Wood',
            offerAmount:    1,
            costsResource: 'EMEventResource',
            costsAmount:    5,
            lots:           1,
            slotType:       0,
        });
        const trade = parseCapturedCall().rmsg.body[0].data;
        expect(trade.slotPos).toBe(0);
    });

    it('dispatchTrade (private, slotType=4): does not auto-pick and does not touch slot map', async () => {
        sandbox.window._tsoOwnPublicTradeSlots = { 2: { 0: true } };
        await sandbox.window._TSORPC.dispatchTrade({
            receipientId:   1928723,
            offerResource: 'Plank',
            offerAmount:    1500,
            costsResource: 'Wood',
            costsAmount:    1,
            slotType:       4, // default anyway; asserted below
        });
        const trade = parseCapturedCall().rmsg.body[0].data;
        expect(trade.slotType).toBe(4);
        expect(trade.slotPos).toBe(0);
        // Private trade must NOT claim a public slot.
        expect(sandbox.window._tsoOwnPublicTradeSlots).toEqual({ 2: { 0: true } });
    });

    it('dispatchCancelTrade: dServerCall.type=1056, data is a bare dIntegerVO carrying the trade id', async () => {
        await sandbox.window._TSORPC.dispatchCancelTrade({ tradeId: 42761633 });
        const { rmsg } = parseCapturedCall();
        const call    = rmsg.body[0];
        const payload = call.data;

        expect(call.type).toBe(1056);
        expect(payload.__class).toBe('defaultGame.Communication.VO.dIntegerVO');
        // Trait member order pinned — this is load-bearing on the wire.
        expect(Object.keys(payload)).toEqual(['__class', 'value']);
        expect(payload.value).toBe(42761633);
    });

    it('dispatchSpecialist rejects with auth error when _tsoAuthCtx is missing', async () => {
        sandbox.window._tsoAuthCtx = null;
        await expect(
            sandbox.window._TSORPC.dispatchSpecialist({
                uid1: 1, uid2: 2, actionType: 0, taskCode: 0, targetGrid: 0,
            })
        ).rejects.toThrow(/auth not ready/);
        expect(captured).toBeNull();
    });
});
