import { describe, it, expect, beforeEach } from 'vitest';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const THIS_DIR = path.dirname(fileURLToPath(import.meta.url));
const JS_DIR   = path.resolve(THIS_DIR, '../TSOClient/TSOClient/Resources/JS');

// amf3-net needs more globals than createAMFSandbox provides — setTimeout,
// XMLHttpRequest, WebSocket, the AMF parser + classifier + scanner. Build the
// sandbox locally so we can swap in spies per test without polluting the
// shared loader.
function buildNetSandbox({ withWS = false } = {}) {
    const logs = [];
    const timers = [];
    const parserCalls = [];
    const scannerCalls = [];
    const classifierCalls = [];

    // Minimal AMFParser stub — parseEnvelope returns a single body shaped like
    // the classifier's learnFromOutbound expects (so we exercise that path
    // without pulling the real parser in).
    function FakeParser(buf) {
        parserCalls.push(buf);
    }
    FakeParser.prototype.parseEnvelope = function() {
        return [{
            target: 'null', response: '/1',
            value: [{
                __class: 'flex.messaging.messages.RemotingMessage',
                headers: { DSId: 'ds-test' },
                body: [{
                    __class: 'defaultGame.Communication.VO.dServerCall',
                    type: 95,
                    zoneID: 42,
                    dsoAuthToken: 'tok', dsoAuthRandomClientID: 'rcid', dsoAuthUser: 'u',
                    data: {
                        __class: 'defaultGame.Communication.VO.dServerAction',
                        type: 1, grid: 0, endGrid: 0,
                        data: {
                            __class: 'defaultGame.Communication.VO.dStartSpecialistTaskVO',
                            uniqueID: { uniqueID1: 1, uniqueID2: 2 },
                            subTaskID: 0, paramString: null,
                        },
                    },
                }],
            }],
        }];
    };

    // XHR stub — amf3-net wraps prototype.open / prototype.send, so we just
    // need a constructor with a prototype. Tests don't exercise XHR end-to-end.
    function FakeXHR() {}
    FakeXHR.prototype.open = function() {};
    FakeXHR.prototype.send = function() {};
    FakeXHR.prototype.addEventListener = function() {};

    const sandbox = {
        window: {
            _TSOAMFParser: FakeParser,
            _tsoClassifier: {
                learnFromOutbound: (bodies) => { classifierCalls.push(bodies); },
            },
            _tsoScanner: {
                analyzeAMFBuffer: (buf, channel) => { scannerCalls.push({ buf, channel }); },
            },
            // Bridge usually installs this; stub it so amf3-net's gated _tsoDiagLog
            // calls don't blow up when diag is off.
            _tsoDiagLog: () => {},
        },
        console,
        TextEncoder, TextDecoder,
        Blob, ArrayBuffer, Uint8Array, Promise,
        webkit: { messageHandlers: { logger: { postMessage: (s) => logs.push(s) } } },
        // Capturing setTimeout — store callbacks, fire on demand so we can
        // assert both the "scheduled but not yet run" and "run" states.
        setTimeout: (fn) => { timers.push(fn); return timers.length; },
        XMLHttpRequest: FakeXHR,
    };
    if (withWS) {
        // Stub constructor so the WS hook installs; tests don't exercise WS frames.
        function FakeWS() { this.addEventListener = () => {}; this.send = () => {}; }
        sandbox.window.WebSocket = FakeWS;
    }

    vm.createContext(sandbox);

    // Pre-stub the inbound fetch the IIFE will wrap. Each test reassigns
    // sandbox.window.fetch to control response shape (or absence).
    sandbox.window.fetch = () => Promise.resolve({
        headers: { get: () => 'application/x-amf' },
        clone() {
            return {
                arrayBuffer: () => Promise.resolve(new ArrayBuffer(16)),
                text:        () => Promise.resolve(''),
            };
        },
    });

    const src = fs.readFileSync(path.join(JS_DIR, 'amf3-net.js'), 'utf8');
    vm.runInContext(src, sandbox, { filename: 'amf3-net.js' });

    return { sandbox, logs, timers, parserCalls, scannerCalls, classifierCalls };
}

describe('amf3-net', () => {
    describe('outbound capture deferral', () => {
        it('does not parse synchronously — schedules onto setTimeout', async () => {
            const { sandbox, timers, parserCalls } = buildNetSandbox();
            const body = new ArrayBuffer(8);
            await sandbox.window.fetch('https://r03-gs.example/GameServer/amf', {
                method: 'POST', body,
            });
            // Defer fired but parser hasn't run yet.
            expect(timers.length).toBeGreaterThan(0);
            expect(parserCalls.length).toBe(0);
            // Now run the deferred callback.
            timers.forEach((fn) => fn());
            expect(parserCalls.length).toBe(1);
        });

        it('parses outbound body exactly once (no double-parse for the recon log)', () => {
            const { sandbox, timers, parserCalls } = buildNetSandbox();
            sandbox.window.fetch('https://r03-gs.example/GameServer/amf', {
                method: 'POST', body: new ArrayBuffer(8),
            });
            timers.forEach((fn) => fn());
            // Pre-dedupe behaviour created two AMFParsers per body — one for
            // cacheAuthCtx/learnFromOutbound, another for logAllOutboundCalls.
            expect(parserCalls.length).toBe(1);
        });

        it('still runs the auth + classifier consumers after the defer fires', () => {
            const { sandbox, timers, classifierCalls } = buildNetSandbox();
            sandbox.window.fetch('https://r03-gs.example/GameServer/amf', {
                method: 'POST', body: new ArrayBuffer(8),
            });
            timers.forEach((fn) => fn());
            expect(classifierCalls.length).toBe(1);
            // cacheAuthCtx populated window._tsoAuthCtx from the fake envelope.
            expect(sandbox.window._tsoAuthCtx).toBeDefined();
            expect(sandbox.window._tsoAuthCtx.zoneID).toBe(42);
            expect(sandbox.window._tsoAuthCtx.DSId).toBe('ds-test');
        });
    });

    describe('outbound URL filter', () => {
        it('skips capture for non-game POSTs in normal mode', () => {
            const { sandbox, timers, parserCalls } = buildNetSandbox();
            sandbox.window.fetch('https://analytics.example.com/track', {
                method: 'POST', body: new ArrayBuffer(8),
            });
            expect(timers.length).toBe(0);
            expect(parserCalls.length).toBe(0);
        });

        it('captures non-game POSTs when _tsoDiag is on (recon mode)', () => {
            const { sandbox, timers } = buildNetSandbox();
            sandbox.window._tsoDiag = true;
            sandbox.window.fetch('https://analytics.example.com/track', {
                method: 'POST', body: new ArrayBuffer(8),
            });
            expect(timers.length).toBeGreaterThan(0);
        });
    });

    describe('recon logging gate', () => {
        it('does not emit [Net:out:fetch] when diag is off', () => {
            const { sandbox, logs } = buildNetSandbox();
            sandbox.window.fetch('https://r03-gs.example/GameServer/amf', {
                method: 'POST', body: new ArrayBuffer(8),
            });
            expect(logs.some((l) => l.startsWith('[Net:out:fetch]'))).toBe(false);
        });

        it('emits [Net:out:fetch] when diag is on', () => {
            const { sandbox, logs } = buildNetSandbox();
            sandbox.window._tsoDiag = true;
            sandbox.window.fetch('https://r03-gs.example/GameServer/amf', {
                method: 'POST', body: new ArrayBuffer(8),
            });
            expect(logs.some((l) => l.startsWith('[Net:out:fetch]'))).toBe(true);
        });
    });

    describe('inbound scanner', () => {
        it('defers analyzeAMFBuffer onto setTimeout', async () => {
            const { sandbox, timers, scannerCalls } = buildNetSandbox();
            await sandbox.window.fetch('https://r03-gs.example/GameServer/amf');
            // arrayBuffer().then() ran first to enqueue the defer; flush
            // any extra microtasks so the timer is registered before assert.
            await new Promise((r) => r());
            // The deferred scan callback is now queued, parser still untouched.
            expect(scannerCalls.length).toBe(0);
            // Run scheduled callbacks → scanner fires.
            const before = scannerCalls.length;
            timers.forEach((fn) => fn());
            expect(scannerCalls.length).toBeGreaterThan(before);
            expect(scannerCalls[0].channel).toBe('fetch');
        });

        it('skips analyzeAMFBuffer for the settingsdefine endpoint', async () => {
            const { sandbox, timers, scannerCalls } = buildNetSandbox();
            await sandbox.window.fetch('https://r03-ls.thesettlersonline.com/settingsdefine?lang=en');
            await new Promise((r) => r());
            timers.forEach((fn) => fn());
            expect(scannerCalls.length).toBe(0);
        });
    });

    describe('chat / XMPP gating', () => {
        // The IIFE captures origFetch at load time, so a chat-flavoured fetch
        // has to be installed BEFORE buildNetSandbox runs. Easiest path is to
        // bypass buildNetSandbox's default and construct the sandbox inline
        // with a chat-shaped origFetch.
        function buildChatSandbox(diag) {
            const ctx = buildNetSandbox();
            // Reach into the closure-captured origFetch via the wrapper itself:
            // since the wrapper delegates to origFetch we instead just call its
            // inbound branch directly by re-installing window.fetch and re-
            // loading amf3-net to recapture origFetch. Simpler in practice.
            const logs = [];
            const sandbox = {
                window: { ...ctx.sandbox.window,
                    fetch: () => Promise.resolve({
                        headers: { get: () => 'text/xml' },
                        clone: () => ({
                            text: () => Promise.resolve('<body><message>hi</message></body>'),
                            arrayBuffer: () => Promise.resolve(new ArrayBuffer(0)),
                        }),
                    }),
                },
                console,
                TextEncoder, TextDecoder, Blob, ArrayBuffer, Uint8Array, Promise,
                webkit: { messageHandlers: { logger: { postMessage: (s) => logs.push(s) } } },
                setTimeout: (fn) => { fn(); },
                XMLHttpRequest: function() { this.open=()=>{}; this.send=()=>{}; this.addEventListener=()=>{}; },
            };
            sandbox.window._tsoWSHooked = true; // skip the WS install branch
            if (diag) sandbox.window._tsoDiag = true;
            vm.createContext(sandbox);
            const src = fs.readFileSync(path.join(JS_DIR, 'amf3-net.js'), 'utf8');
            vm.runInContext(src, sandbox, { filename: 'amf3-net.js' });
            return { sandbox, logs };
        }

        it('does not log inbound chat bodies when diag is off', async () => {
            const { sandbox, logs } = buildChatSandbox(false);
            await sandbox.window.fetch('https://r03-chat.example/http-bind/');
            // Flush the clone().text() microtask chain.
            await new Promise((r) => setImmediate(r));
            expect(logs.some((l) => l.startsWith('[XMPP:in]'))).toBe(false);
            expect(logs.some((l) => l.startsWith('[Trade:chat:in]'))).toBe(false);
        });

        it('logs inbound chat bodies when diag is on', async () => {
            const { sandbox, logs } = buildChatSandbox(true);
            await sandbox.window.fetch('https://r03-chat.example/http-bind/');
            await new Promise((r) => setImmediate(r));
            expect(logs.some((l) => l.startsWith('[XMPP:in]') ||
                                    l.startsWith('[Trade:chat:in]'))).toBe(true);
        });
    });
});
