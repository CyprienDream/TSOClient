import { describe, it, expect, beforeEach } from 'vitest';
import { createAMFSandbox, loadModule } from './loadModule.js';

describe('amf3-classifier', () => {
    let sandbox;
    let cls;

    beforeEach(() => {
        sandbox = createAMFSandbox();
        loadModule(sandbox, 'amf3-classifier');
        cls = sandbox.window._tsoClassifier;
    });

    describe('subtypeNameFor', () => {
        it('resolves canonical explorer/geologist/general names', () => {
            expect(cls.subtypeNameFor(1)).toBe('Explorer');
            expect(cls.subtypeNameFor(2)).toBe('Geologist');
            expect(cls.subtypeNameFor(35)).toBe('StoneColdGeologist');
            expect(cls.subtypeNameFor(59)).toBe('DiligentGeologist');
            expect(cls.subtypeNameFor(74)).toBe('PirateExplorer');
            expect(cls.subtypeNameFor(0)).toBe('General');
        });

        it('returns null for unmapped numeric IDs', () => {
            expect(cls.subtypeNameFor(9999)).toBeNull();
        });
    });

    describe('classifyFromTask', () => {
        it('FindDeposit task → Geologist', () => {
            expect(cls.classifyFromTask({ __class: 'dSpecialistTask_FindDepositVO' }))
                .toBe('Geologist');
        });

        it('FindTreasure / FindEventZone task → Explorer', () => {
            expect(cls.classifyFromTask({ __class: 'dSpecialistTask_FindTreasureVO' }))
                .toBe('Explorer');
            expect(cls.classifyFromTask({ __class: 'dSpecialistTask_FindEventZoneVO' }))
                .toBe('Explorer');
        });

        it('null task / unknown class → null', () => {
            expect(cls.classifyFromTask(null)).toBeNull();
            expect(cls.classifyFromTask({})).toBeNull();
            expect(cls.classifyFromTask({ __class: 'Mystery' })).toBeNull();
        });
    });

    describe('classifySpec priority', () => {
        it('garrison >= 0 is authoritative → General regardless of subtype', () => {
            // subtype 1 normally → Explorer, but garrison pin wins.
            expect(cls.classifySpec(1, 47, '')).toBe('General');
        });

        it('subtype table beats numeric specialistType for the non-General case', () => {
            expect(cls.classifySpec(1, -1, '')).toBe('Explorer');
            expect(cls.classifySpec(2, -1, '')).toBe('Geologist');
            expect(cls.classifySpec(35, -1, '')).toBe('Geologist');
        });

        it('numeric specialistType 0 / 3 → General when garrison missing', () => {
            // 0/3 are Generals without a garrison pin (e.g. unassigned).
            expect(cls.classifySpec(0, -1, '')).toBe('General');
            expect(cls.classifySpec(3, -1, '')).toBe('General');
        });

        it('falls back to name keyword for unknown numeric IDs', () => {
            expect(cls.classifySpec(9999, -1, 'Strange Geologist')).toBe('Geologist');
            expect(cls.classifySpec(9999, -1, 'New EXPLORER Variant')).toBe('Explorer');
            expect(cls.classifySpec(9999, -1, 'Mystery General X')).toBe('General');
        });

        it('defaults unknown IDs to Explorer (most premium drops are explorers)', () => {
            expect(cls.classifySpec(9999, -1, 'Unknown')).toBe('Explorer');
            expect(cls.classifySpec(9999, -1, '')).toBe('Explorer');
        });
    });

    describe('learnFromOutbound', () => {
        // Mirror the parseEnvelope() output shape: [{target, response, value}]
        // where value is the parsed AMF3 array carrying RemotingMessages.
        function fakeBodies({ actionType, uid1, uid2 }) {
            return [{
                target: 'null', response: '/1',
                value: [{
                    __class: 'flex.messaging.messages.RemotingMessage',
                    body: [{
                        __class: 'defaultGame.Communication.VO.dServerCall',
                        type: 95,
                        data: {
                            __class: 'defaultGame.Communication.VO.dServerAction',
                            type: actionType,
                            data: {
                                __class: 'defaultGame.Communication.VO.dStartSpecialistTaskVO',
                                uniqueID: { uniqueID1: uid1, uniqueID2: uid2 },
                                subTaskID: 0, paramString: null,
                            },
                        },
                    }],
                }],
            }];
        }

        it('actionType 0 → Geologist hint', () => {
            cls.learnFromOutbound(fakeBodies({ actionType: 0, uid1: 7, uid2: 8 }));
            expect(sandbox.window._tsoSpecTypeHints['7:8']).toBe('Geologist');
        });

        it('actionType 1 or 2 → Explorer hint', () => {
            cls.learnFromOutbound(fakeBodies({ actionType: 1, uid1: 1, uid2: 1 }));
            cls.learnFromOutbound(fakeBodies({ actionType: 2, uid1: 2, uid2: 2 }));
            expect(sandbox.window._tsoSpecTypeHints['1:1']).toBe('Explorer');
            expect(sandbox.window._tsoSpecTypeHints['2:2']).toBe('Explorer');
        });

        it('actionType 12 → General hint', () => {
            cls.learnFromOutbound(fakeBodies({ actionType: 12, uid1: 3, uid2: 4 }));
            expect(sandbox.window._tsoSpecTypeHints['3:4']).toBe('General');
        });

        it('skips dispatches the app issued itself (matches window._tsoOwnDispatch)', () => {
            sandbox.window._tsoOwnDispatch = '9:9';
            cls.learnFromOutbound(fakeBodies({ actionType: 0, uid1: 9, uid2: 9 }));
            expect(sandbox.window._tsoSpecTypeHints).toBeUndefined();
        });

        it('non-95 calls are ignored', () => {
            const bodies = fakeBodies({ actionType: 0, uid1: 1, uid2: 2 });
            bodies[0].value[0].body[0].type = 61;
            cls.learnFromOutbound(bodies);
            expect(sandbox.window._tsoSpecTypeHints).toBeUndefined();
        });
    });
});
