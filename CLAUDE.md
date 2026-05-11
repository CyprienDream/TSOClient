# TSOClient — Claude context

## What this project is

A native macOS wrapper around The Settlers Online (TSO), built as an automation and enhancement platform. The game runs inside a `WKWebView`. The current TSO client is a **Unity WebGL** build (the original Flash client was retired with Flash itself; a brief HTML5 era preceded Unity). The backend protocol is unchanged — GameServer responses are still AMF3/Flex over `fetch`, which is why the AMF3 scanner keeps working. Behaviour is extended through injected JavaScript that intercepts network responses and substitutes textures to highlight collectibles. Swift owns the native chrome, data models, and image processing; JavaScript owns in-page interception and texture patching.

**Unity-client implications** (do not relearn each session):
- The game canvas is a single WebGL2 context; there is no JS-accessible game state (`window.s_oIsland` / `s_oMain` / `s_oGame` etc. **do not exist**). Camera position lives inside the wasm heap.
- Building textures **are** fetched individually via `fetch()` from Ubisoft's CDN (`ubistatic-a.akamaihd.net/frontend/GFX_HASHED/building_lib/<sha1>.png`). This is how the collectible texture patcher works: it intercepts those fetches and returns a synthetic pink PNG for known collectible hashes. `<img>` elements are not used for game art, so the `tso-asset://` URL rewriter is dormant.
- `gameevents.registerHook` exposes only coarse lifecycle triggers (`triggerLevelUp`, `triggerTutorialEnd`, `triggerFriendInvite`, `triggerClientLoaded`); not useful for game-state reading.

The long-term goal is a full automation suite: collectible highlighting, explorer/specialist dispatch, buffing, adventure management. The **Collectible Highlighter** shipped (via texture substitution). The current milestone is **Specialist Dispatch**.

**What a collectible is:** a resource item (herbs, banner, food cart, etc.) that spawns at a random map tile on the player's island and is picked up by clicking. *Not* a building, and *not* the per-building "ready to collect" stockpile (`dPersistedPickupItemVO`, e.g. "879 TitaniumOre at the Titanium Mine"). The feature mirrors what the **Pinky** Chrome extension and the Windows AIR client (`fedorovvl/tso_client`) do for the same game.

## Important
The file log.md contains all the findings of the investigation so far, the current state of the project, the details from the last sesion as well as the next steps for the current session.

## Repo layout

```
TSOClient/                  ← Xcode project root
  TSOClient.xcodeproj/
  TSOClient/                ← source root (all Swift + assets)
    TSOClientApp.swift      ← @main, window sizing (1280×900)
    ContentView.swift       ← WebView NSViewRepresentable + 3 active JS modules (jsOverlay + jsURLRewriter retained as commented-out dead code)
    BridgeProtocol.swift    ← InboundMessage / OutboundMessage Swift types
    CollectiblesStore.swift ← @Observable data model for parsed collectibles
    CollectiblesHighlighter.swift ← WKURLSchemeHandler: tso-asset:// → CDN fetch + glow
    Info.plist              ← NSAllowsArbitraryLoads = true (game CDN needs it)
    TSOClient.entitlements  ← sandbox + network.client
```

## Architecture in one paragraph

`WebView` loads `thesettlersonline.com`. Three JS modules are injected at `atDocumentStart` in dependency order: **jsBridge** (sets up `window.TSOBridge` for Swift→JS and `window._tsoSend` for JS→Swift), **jsAMF3Scanner** (wraps `window.fetch` and `XMLHttpRequest`, deserialises GameServer AMF3 binary responses, walks the object tree to locate spawned-collectible VOs and the zone's `mapWidth`/`mapHeight`), **jsCollectiblePatcher** (wraps `fetch` + `XHR` on the request side; for 55 known collectible building-texture hashes returns a 32×32 hot-pink synthetic PNG so Unity renders those buildings pink in-world). Two additional modules — **jsOverlay** (canvas overlay with isometric marker renderer) and **jsURLRewriter** — are retained in source but commented out of the injection list; the overlay approach was abandoned in favour of texture substitution. JS→Swift uses two named `WKScriptMessageHandler` channels: `"logger"` (raw strings) and `"tso"` (structured `{type, payload}` JSON). Swift→JS goes through `webView.evaluateJavaScript("window.TSOBridge.receive({…})")`. `CollectiblesStore` is `@Observable`; the `Coordinator` mutates it on main thread when `COLLECTIBLES` messages arrive.

## Bridge protocol

**JS → Swift (`"tso"` handler):**
- `COLLECTIBLES` — `{mapWidth, mapHeight, items:[{gridIndex,x,y,assetName}]}`
- `GAME_STATE`   — `{state:"LOADED"|"ZONE_CHANGED"|"ZONE_LEFT", zoneId?}`
- `CALIBRATION_DONE` — *(legacy — overlay disabled; never fired)*

**Swift → JS (`OutboundMessage.send(to:)`):**
- `SET_OVERLAY`, `SET_OVERLAY_COLOR`, `CALIBRATE`, `RENDER` — *(all legacy — overlay disabled; code retained but never called)*

## Highlighting approach (replaced overlay)

Collectibles are highlighted by **texture substitution**: `jsCollectiblePatcher` intercepts `fetch()` and `XMLHttpRequest` calls for collectible building PNG textures (matched by SHA-1 hash against a 55-entry list from Pinky's `live.json`) and returns a synthetic 32×32 hot-pink image instead. Unity uploads the substituted bytes as a GL texture and renders the collectible pink in-world. No overlay canvas, no calibration, no camera tracking is needed.

The `jsOverlay` canvas approach (isometric formula, two-point calibration, `requestAnimationFrame` camera reader) was abandoned in Iteration 7 because Unity renders via its wasm heap — no JS-accessible camera globals exist — and calibration was fragile. The module remains in `ContentView.swift` as dead code for reference.

`HighlightSchemeHandler` is still registered for the `tso-asset://` scheme but never triggered: nothing generates `tso-asset://` URLs under the current architecture. It can be removed without impact.

## Key invariants

- `updateNSView` guards `webView.url == nil` — do not remove this or the game reloads on every SwiftUI state change.
- Injection order: `jsBridge` first (others call `window._tsoSend`), then `jsAMF3Scanner`, then `jsCollectiblePatcher`. The patcher must run **after** the scanner because it wraps the scanner's already-patched `window.fetch`; reversing the order breaks AMF3 parsing on non-collectible URLs.
- `WKUserContentController.add(_:name:)` retains the handler — the `Coordinator` is already `NSObject`, no extra wrapper needed.
- `HighlightSchemeHandler` is still registered for `"tso-asset"` but never invoked. Safe to ignore.
- `@Observable` (Swift 5.9 macro, not `ObservableObject`). Use `@State` at the owner site, pass by value to child views — the class reference propagates automatically.

## Xcode practices (token efficiency)

- **Read changed files only.** The project is small; `ContentView.swift` holds all five JS modules (three injected, two dead code) as Swift string literals — read it whole rather than grepping for fragments.
- **Build via CLI** to get structured errors without opening Xcode:
  ```
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
- **Scheme handler errors** appear as `net::ERR_FAILED` in the WebView, not in Xcode. Test by adding `print` in `HighlightSchemeHandler.webView(_:start:)`.

## What does NOT exist yet

- Specialist/explorer dispatch (the next milestone — see `explorer-feature.md` for the plan).
- Any SwiftUI chrome — the window is currently 100% WebView with no native controls.
- Outbound AMF3 capability — the scanner parses incoming responses but never sends to GameServer.
- Persistent storage of dispatch templates or any app settings.
- Buff management, adventure features, trading, building automation.
- Unit or UI tests.
