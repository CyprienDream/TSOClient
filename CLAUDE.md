# TSOClient — Claude context

## What this project is

A native macOS wrapper around The Settlers Online (TSO), built as an automation and enhancement platform. The game runs inside a `WKWebView`. The current TSO client is a **Unity WebGL** build (the original Flash client was retired with Flash itself; a brief HTML5 era preceded Unity). The backend protocol is unchanged — GameServer responses are still AMF3/Flex over `fetch`, which is why the AMF3 scanner keeps working. Behaviour is extended through injected JavaScript that intercepts those network responses, draws an HTML overlay above the Unity canvas, and manipulates the surrounding DOM site chrome. Swift owns the native chrome, data models, and image processing; JavaScript owns in-page logic and the visual overlay.

**Unity-client implications** (do not relearn each session):
- The game canvas is a single WebGL2 context; there is no JS-accessible game state (`window.s_oIsland` / `s_oMain` / `s_oGame` etc. **do not exist**). Camera position lives inside the wasm heap.
- Sprites are uploaded to GL textures from a binary atlas, not fetched as individual `<img>` URLs. The `tso-asset://` URL rewriter and `HighlightSchemeHandler` therefore see ~zero matches against game art and are effectively dormant; they're retained only because they're cheap and may still catch DOM-based site UI imagery.
- `gameevents.registerHook` exposes only coarse lifecycle triggers (`triggerLevelUp`, `triggerTutorialEnd`, `triggerFriendInvite`, `triggerClientLoaded`); not useful for camera tracking.
- Camera tracking for the overlay must come from JS-observable user input (pointer drag on the canvas, wheel, keyboard) or from hooking the WebGL view-projection matrix at `uniformMatrix4fv` — not from reading game globals.

The long-term goal is a full automation suite: collectible highlighting, explorer dispatch, buffing, adventure management. The current milestone is the **Collectible Highlighter**.

**What a collectible is:** a resource item (herbs, banner, food cart, etc.) that spawns at a random map tile on the player's island and is picked up by clicking. *Not* a building, and *not* the per-building "ready to collect" stockpile (`dPersistedPickupItemVO`, e.g. "879 TitaniumOre at the Titanium Mine"). The feature mirrors what the **Pinky** Chrome extension and the Windows AIR client (`fedorovvl/tso_client`) do for the same game.

## Important
The file log.md contains all the findings of the investigation so far, the current state of the project, the details from the last sesion as well as the next steps for the current session.

## Repo layout

```
TSOClient/                  ← Xcode project root
  TSOClient.xcodeproj/
  TSOClient/                ← source root (all Swift + assets)
    TSOClientApp.swift      ← @main, window sizing (1280×900)
    ContentView.swift       ← WebView NSViewRepresentable + 4 injected JS modules
    BridgeProtocol.swift    ← InboundMessage / OutboundMessage Swift types
    CollectiblesStore.swift ← @Observable data model for parsed collectibles
    CollectiblesHighlighter.swift ← WKURLSchemeHandler: tso-asset:// → CDN fetch + glow
    Info.plist              ← NSAllowsArbitraryLoads = true (game CDN needs it)
    TSOClient.entitlements  ← sandbox + network.client
```

## Architecture in one paragraph

`WebView` loads `thesettlersonline.com`. Four JS modules are injected at `atDocumentStart` in dependency order: **jsBridge** (sets up `window.TSOBridge` for Swift→JS and `window._tsoSend` for JS→Swift), **jsOverlay** (transparent fixed `<canvas>` at `z-index:1000` so DOM popups stay above it, isometric marker renderer, calibration engine, `requestAnimationFrame` camera-reader loop), **jsAMF3Scanner** (wraps `window.fetch`, deserialises GameServer AMF3 binary responses, walks the object tree to locate spawned-collectible VOs and the zone's `mapWidth`/`mapHeight`), **jsURLRewriter** (rewrites collectible `<img>` src to `tso-asset://` for the Swift glow handler — dormant under the Unity client; see implications above). JS→Swift uses two named `WKScriptMessageHandler` channels: `"logger"` (raw strings) and `"tso"` (structured `{type, payload}` JSON). Swift→JS goes through `webView.evaluateJavaScript("window.TSOBridge.receive({…})")`. `CollectiblesStore` is `@Observable`; the `Coordinator` mutates it on main thread when `COLLECTIBLES` messages arrive.

## Bridge protocol

**JS → Swift (`"tso"` handler):**
- `COLLECTIBLES` — `{mapWidth, mapHeight, items:[{gridIndex,x,y,assetName}]}`
- `GAME_STATE`   — `{state:"LOADED"|"ZONE_CHANGED"|"ZONE_LEFT", zoneId?}`
- `CALIBRATION_DONE` — `{tileHW, tileHH, originX, originY}`

**Swift → JS (`OutboundMessage.send(to:)`):**
- `SET_OVERLAY`       — `{enabled: bool}`
- `SET_OVERLAY_COLOR` — `{color: "#rrggbb"}`
- `CALIBRATE`         — `{gx1,gy1,sx1,sy1,gx2,gy2,sx2,sy2}`
- `RENDER`            — (no payload, force redraw)

## Overlay coordinate system

Standard isometric formula:
```
screenX = (gridX - gridY) * tileHW + originX
screenY = (gridX + gridY) * tileHH + originY
```
Defaults: `tileHW=32, tileHH=16` (64×32 px tiles). Two-point calibration via `window._TSOOverlay.calibrate(gx1,gy1,sx1,sy1,gx2,gy2,sx2,sy2)`; calibration is stored in **world-space** so it survives camera pans. Camera pan was originally tracked via `MutationObserver` on the game canvas's CSS transform — that approach was abandoned in Iteration 7 because Unity pans the camera inside its wasm heap, not via DOM/CSS. Current binding: a `requestAnimationFrame` loop in `jsOverlay` calls the first non-null candidate in `buildCandidates()` each frame; under the Unity client the legacy `s_oIsland` / `s_oMain` / `s_oGame` / `s_oScene` accessors all return null, so the rendered camera offset stays at zero until a Unity-aware reader (input-tracking or WebGL matrix hook) is added.

## Key invariants

- `updateNSView` guards `webView.url == nil` — do not remove this or the game reloads on every SwiftUI state change.
- JS modules are injected in order; `jsBridge` must be first because the others call `window._tsoSend`.
- `WKUserContentController.add(_:name:)` retains the handler — the `Coordinator` is already `NSObject`, no extra wrapper needed.
- `HighlightSchemeHandler` registered for scheme `"tso-asset"`. The scheme handler and the URL rewriter are independent layers; both can coexist. Both are dormant under the Unity client (sprites come from a GL atlas, not URL fetches) but cheap to keep injected.
- `@Observable` (Swift 5.9 macro, not `ObservableObject`). Use `@State` at the owner site, pass by value to child views — the class reference propagates automatically.

## Xcode practices (token efficiency)

- **Read changed files only.** The project is small; `ContentView.swift` holds all four JS modules as Swift string literals — read it whole rather than grepping for fragments.
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

- Any SwiftUI controls (the window is currently 100% WebView).
- Persistent calibration storage (calibration is lost on restart).
- A working camera reader for the Unity client (overlay markers don't track pan yet).
- Explorer dispatch, buff management, adventure features.
- Unit or UI tests.
