(function() {
    'use strict';

    // Captures the Unity instance so window._tsoUnity is reachable from anywhere.
    // Reconnaissance via this probe (sessions ending 2026-05-23) confirmed that
    // Unity does NOT use the JS SendMessage bridge for in-game UI actions and
    // that the wasm has no symbolic exports we could call — so the instance is
    // mainly useful for future debugging, not for driving UI refresh. See log.md
    // section "Approach 1 dead end — Unity local UI authority" for details.
    //
    // How we beat the loader race: a MutationObserver installed at atDocumentStart
    // fires as a microtask between consecutive <script> tag executions. When the
    // Unity loader script defines window.createUnityInstance, the MO callback
    // wraps it before the next <script> tag invokes it. The Object.defineProperty
    // patch and accessor watcher handle the rare cases where the loader uses one
    // of those code paths instead of a function declaration. A 1 s slow-poll runs
    // for 60 s as a backup if all three fast paths miss.

    var PATH = '';
    try { PATH = (location.pathname || location.href || '?'); } catch(e) {}
    var FRAME = '[' + PATH.slice(-60) + '] ';
    var IS_GAME_FRAME = /\/play(\b|\/|$)/i.test(PATH);

    function L(msg) {
        try { webkit.messageHandlers.logger.postMessage('[UnityProbe] ' + FRAME + msg); } catch(e) {}
    }

    var captured = false;
    var origDP = Object.defineProperty;

    function onUnityReady(inst, source) {
        if (captured) return;
        captured = true;
        window._tsoUnity = inst;
        L('instance ready (via ' + source + '); window._tsoUnity exposed');
    }

    function wrapCreateUnity(orig) {
        if (orig.__tsoWrapped) return orig;
        var wrapped = function() {
            var ret;
            try { ret = orig.apply(this, arguments); }
            catch(e) { L('createUnityInstance threw: ' + e); throw e; }
            if (ret && typeof ret.then === 'function') {
                ret.then(function(inst) {
                    onUnityReady(inst, 'createUnityInstance');
                }, function(err) {
                    L('createUnityInstance rejected: ' + err);
                });
            }
            return ret;
        };
        wrapped.__tsoWrapped = true;
        return wrapped;
    }

    function tryWrapUnwrappedCUI() {
        var fn;
        try { fn = window.createUnityInstance; } catch(e) { return false; }
        if (typeof fn === 'function' && !fn.__tsoWrapped) {
            try {
                origDP.call(Object, window, 'createUnityInstance', {
                    configurable: true, writable: true,
                    value: wrapCreateUnity(fn),
                });
                return true;
            } catch(e) {
                try { window.createUnityInstance = wrapCreateUnity(fn); return true; }
                catch(e2) { return false; }
            }
        }
        return false;
    }

    // Object.defineProperty patch (catches DefineProperty-based assignment).
    try {
        Object.defineProperty = function(target, key, desc) {
            if (target === window && key === 'createUnityInstance' &&
                desc && typeof desc.value === 'function' && !desc.value.__tsoWrapped) {
                try { desc = Object.assign({}, desc, { value: wrapCreateUnity(desc.value) }); } catch(e) {}
            }
            return origDP.apply(this, arguments);
        };
    } catch(e) {}

    // Accessor watcher (catches `window.createUnityInstance = fn`).
    (function installAccessor() {
        if ('createUnityInstance' in window) return;
        var slot;
        try {
            origDP.call(Object, window, 'createUnityInstance', {
                configurable: true,
                get: function() { return slot; },
                set: function(v) { slot = (typeof v === 'function') ? wrapCreateUnity(v) : v; }
            });
        } catch(e) {}
    })();

    // MutationObserver — the primary path. Fires as a microtask between <script>
    // tags, giving us a wrap point after the loader and before the caller.
    function installMO() {
        var target = document.documentElement || document.head || document.body || document;
        if (!target) { setTimeout(installMO, 0); return; }
        try {
            var observer = new MutationObserver(function() {
                if (captured) return;
                tryWrapUnwrappedCUI();
            });
            observer.observe(target, { childList: true, subtree: true });
        } catch(e) {}
    }
    installMO();

    // Slow-poll backup, only on the game frame, only briefly.
    if (IS_GAME_FRAME) {
        var attempts = 0;
        (function poll() {
            if (captured || attempts >= 60) return;
            attempts++;
            tryWrapUnwrappedCUI();
            setTimeout(poll, 1000);
        })();
    }

    // Manual entry points for ad-hoc exploration via Safari Web Inspector.
    //   _tsoUnityProbe.findExports('Specialist')  — list matching wasm exports
    //   _tsoUnityProbe.findExports('^_Send')
    window._tsoUnityProbe = {
        findExports: function(pattern) {
            if (!window._tsoUnity || !window._tsoUnity.Module) return [];
            var re;
            try { re = new RegExp(pattern, 'i'); } catch(e) { return []; }
            return Object.keys(window._tsoUnity.Module).filter(function(k) { return re.test(k); });
        },
    };
})();
