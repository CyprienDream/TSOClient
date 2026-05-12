# TSOClient — Claude context

## What this project is

A native macOS wrapper around The Settlers Online (TSO), built as an automation and enhancement platform. The game runs inside a `WKWebView`. The current TSO client is a **Unity WebGL** build (the original Flash client was retired with Flash itself; a brief HTML5 era preceded Unity). The backend protocol is unchanged — GameServer responses are still AMF3/Flex over `fetch`, which is why the AMF3 scanner keeps working. Behaviour is extended through injected JavaScript that intercepts network responses and substitutes textures to highlight collectibles. Swift owns the native chrome, data models, and image processing; JavaScript owns in-page interception and texture patching.

**Unity-client implications** (do not relearn each session):
- The game canvas is a single WebGL2 context; there is no JS-accessible game state (`window.s_oIsland` / `s_oMain` / `s_oGame` etc. **do not exist**). Camera position lives inside the wasm heap.
- Building textures **are** fetched individually via `fetch()` from Ubisoft's CDN (`ubistatic-a.akamaihd.net/frontend/GFX_HASHED/building_lib/<sha1>.png`). This is how the collectible texture patcher works: it intercepts those fetches and returns a synthetic pink PNG for known collectible hashes. `<img>` elements are not used for game art.
- `gameevents.registerHook` exposes only coarse lifecycle triggers (`triggerLevelUp`, `triggerTutorialEnd`, `triggerFriendInvite`, `triggerClientLoaded`); not useful for game-state reading.

The long-term goal is a full automation suite: collectible highlighting, explorer/specialist dispatch, buffing, adventure management. The **Collectible Highlighter** shipped (via texture substitution). **Specialist Dispatch** is code-complete but not yet verified end-to-end (see `specialist-dispatch.md`).

**What a collectible is:** a resource item (herbs, banner, food cart, etc.) that spawns at a random map tile on the player's island and is picked up by clicking. *Not* a building, and *not* the per-building "ready to collect" stockpile (`dPersistedPickupItemVO`). The feature mirrors what the **Pinky** Chrome extension and the Windows AIR client (`fedorovvl/tso_client`) do for the same game.

## Important
The file `log.md` contains all findings of the investigation so far, the current state of the project, the details from the last session, and next steps for the current session.

## Where to find things

| Concept | Path |
|---|---|
| App entry + root view | `TSOClient/App/` |
| WKWebView wrapper + coordinator + JS injection | `TSOClient/WebView/` |
| Swift↔JS message types + dispatch sender | `TSOClient/Bridge/` |
| Collectibles data model | `TSOClient/Features/Collectibles/` |
| Specialists data model + panel UI + task enums | `TSOClient/Features/Specialists/` |
| Injected JavaScript source files | `TSOClient/Resources/JS/` |
| Collectible texture hashes (55 SHA-1s) | `TSOClient/Resources/Data/collectible-hashes.json` |

## Repo layout

```
TSOClient/                      ← Xcode project root
  TSOClient.xcodeproj/
  TSOClient/                    ← source root (synchronized folder group — no pbxproj edits needed
    TSOClientApp.swift          ← @main, window 1280×900
    App/
      ContentView.swift         ← SwiftUI root (HSplitView + @State stores + BridgeSender)
    WebView/
      WebView.swift             ← NSViewRepresentable wrapper
      WebViewCoordinator.swift  ← WKUIDelegate + WKNavDelegate + WKScriptMessageHandler
      JSInjection.swift         ← loads JS modules from bundle in injection order
      BridgeRouter.swift        ← maps InboundMessage → store mutations
    Bridge/
      InboundMessage.swift      ← JS→Swift message enum + payload decoders
      OutboundMessage.swift     ← Swift→JS message enum + send(to:)
      BridgeSender.swift        ← @Observable; owns weak WKWebView ref for typed dispatch
    Features/
      Collectibles/
        CollectiblesStore.swift ← @Observable collectible items + map dims
      Specialists/
        SpecialistsStore.swift  ← @Observable specialist list
        SpecialistsPanel.swift  ← SwiftUI side panel + SpecialistRow
        SpecialistTasks.swift   ← GeologistTask + ExplorerTask enums
    Resources/
      JS/
        bridge.js               ← window._tsoSend + window.TSOBridge
        amf3-scanner.js         ← AMF3 deserialiser, fetch/XHR interception, auth caching
        amf3-encoder.js         ← AMF3 serialiser + _TSORPC.dispatchSpecialist
        collectible-patcher.js  ← returns pink PNG for 55 known collectible hashes
      Data/
        collectible-hashes.json ← 55 SHA-1 hashes (substituted into patcher at load time)
    Info.plist                  ← NSAllowsArbitraryLoads = true (game CDN needs it)
    TSOClient.entitlements      ← sandbox + network.client
```

## Architecture in one paragraph

`WebView` loads `thesettlersonline.com`. `JSInjection` installs four JS modules at `atDocumentStart` in dependency order: **bridge.js** (sets up `window.TSOBridge` for Swift→JS and `window._tsoSend` for JS→Swift), **amf3-scanner.js** (wraps `window.fetch` and `XMLHttpRequest`, deserialises GameServer AMF3 binary responses, emits `COLLECTIBLES` and `SPECIALISTS` messages, caches auth context in `window._tsoAuthCtx`), **amf3-encoder.js** (AMF3 serialiser, builds `RemotingMessage` envelopes, exposes `_TSORPC.dispatchSpecialist` and registers the `DISPATCH_SPECIALIST` TSOBridge handler), **collectible-patcher.js** (wraps `fetch` + `XHR`; for 55 known collectible building-texture hashes returns a 32×32 hot-pink synthetic PNG so Unity renders those buildings pink in-world). JS→Swift uses two named `WKScriptMessageHandler` channels: `"logger"` (raw strings) and `"tso"` (structured `{type, payload}` JSON). Swift→JS goes through `BridgeSender.send(_ msg: OutboundMessage)`, which calls `webView.evaluateJavaScript(msg.jsExpression)`. `BridgeRouter` maps decoded `InboundMessage` values to store mutations on the main thread.

## Bridge protocol

**JS → Swift (`"tso"` handler):**
- `COLLECTIBLES` — `{mapWidth, mapHeight, items:[{gridIndex,x,y,assetName}]}`
- `GAME_STATE`   — `{state:"LOADED"|"ZONE_CHANGED"|"ZONE_LEFT", zoneId?}`
- `SPECIALISTS`  — `{items:[{uid,uid1,uid2,specialistType,name,level,isIdle,taskEndTime?}]}`

**Swift → JS (`BridgeSender.send(_:)` → `OutboundMessage.jsExpression`):**
- `DISPATCH_SPECIALIST` — `{uid1, uid2, taskCode, targetGrid}` → handled by `amf3-encoder.js`

## Highlighting approach

Collectibles are highlighted by **texture substitution**: `collectible-patcher.js` intercepts `fetch()` and `XMLHttpRequest` calls for collectible building PNG textures (matched by SHA-1 hash against a 55-entry list in `collectible-hashes.json`) and returns a synthetic 32×32 hot-pink image instead. Unity uploads the substituted bytes as a GL texture and renders the collectible pink in-world. No overlay canvas, no calibration, no camera tracking is needed.

The canvas overlay approach was abandoned in Iteration 7 because Unity renders via its wasm heap — no JS-accessible camera globals exist.

## Key invariants

- `WebView.updateNSView` guards `webView.url == nil` — do not remove this or the game reloads on every SwiftUI state change.
- JS injection order: **bridge → scanner → encoder → patcher**. The patcher must run **after** the scanner because it wraps the scanner's already-patched `window.fetch`; reversing the order breaks AMF3 parsing on non-collectible URLs.
- AMF3 VO object-literal member order in `amf3-encoder.js` is load-bearing (trait registration is order-dependent on the wire).
- `WKUserContentController.add(_:name:)` retains the handler — `WebViewCoordinator` is `NSObject`, no extra wrapper needed.
- `@Observable` (Swift 5.9 macro, not `ObservableObject`). Use `@State` at the owner site; the class reference propagates automatically.

## Xcode practices (token efficiency)

- **Synchronized folder group**: adding, renaming, or moving `.swift`, `.js`, `.json` files inside `TSOClient/TSOClient/` requires **no pbxproj edits**. The Xcode project uses `PBXFileSystemSynchronizedRootGroup`.
- **Build via CLI** to get structured errors without opening Xcode:
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TSOClient/TSOClient.xcodeproj \
             -scheme TSOClient \
             -destination 'platform=macOS' \
             build 2>&1 | grep -E "error:|warning:" | head -40
  ```
- **Swift syntax check** a single file without building:
  ```
  swiftc -typecheck -sdk $(xcrun --show-sdk-path) \
         -target arm64-apple-macos14.0 \
         TSOClient/TSOClient/<file>.swift
  ```
- **Entitlements / plist issues** surface at signing time, not compile time — check `TSOClient.entitlements` and `Info.plist` directly if the app crashes at launch.
- **JS debugging**: add `webkit.messageHandlers.logger.postMessage(...)` calls freely; they stream to Xcode console with `[JS]` prefix. Never remove the `"logger"` handler registration.
- **JS files**: edit `Resources/JS/*.js` directly. No recompile needed to change JS logic — only a re-run.

## What does NOT exist yet

- Specialist dispatch verified end-to-end (code complete — see `specialist-dispatch.md`; needs live testing).
- Buff management, adventure features, trading, building automation.
- Persistent storage of dispatch templates or any app settings.
- Unit or UI tests.
