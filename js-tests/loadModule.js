import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const THIS_DIR = path.dirname(fileURLToPath(import.meta.url));
const JS_DIR   = path.resolve(THIS_DIR, '../TSOClient/TSOClient/Resources/JS');

// Each JS module is an IIFE that installs globals on `window` (and consumes
// host-provided things like fetch / webkit.messageHandlers.logger). We run
// each module inside a `vm` context whose globals match the WKWebView surface
// closely enough that the modules execute as-is — no edits to the JS sources.
export function createAMFSandbox() {
    const sandbox = {
        window:      {},
        console,
        TextEncoder,
        TextDecoder,
        crypto:      globalThis.crypto,
        // Stubbed by default; encoder tests overwrite to capture POST bodies.
        fetch:       () => Promise.reject(new Error('fetch not stubbed in this test')),
        // Encoder calls this for diagnostic logs on every dispatch.
        webkit:      { messageHandlers: { logger: { postMessage() {} } } },
    };
    vm.createContext(sandbox);
    return sandbox;
}

export function loadModule(sandbox, name) {
    const file = path.join(JS_DIR, `${name}.js`);
    const src  = fs.readFileSync(file, 'utf8');
    vm.runInContext(src, sandbox, { filename: file });
}
