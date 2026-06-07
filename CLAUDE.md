# TSOClient — Claude context

## What this project is

A native macOS wrapper around The Settlers Online (TSO), built as an automation and enhancement platform. The game runs inside a `WKWebView`. The current TSO client is a **Unity WebGL** build (the original Flash client was retired with Flash itself; a brief HTML5 era preceded Unity). The backend protocol is unchanged — GameServer responses are still AMF3/Flex over `fetch`, which is why the AMF3 scanner keeps working. Behaviour is extended through injected JavaScript that intercepts network responses and substitutes textures to highlight collectibles. Swift owns the native chrome, data models, and image processing; JavaScript owns in-page interception and texture patching.

**Unity-client implications** (do not relearn each session):
- The game canvas is a single WebGL2 context; there is no JS-accessible game state (`window.s_oIsland` / `s_oMain` / `s_oGame` etc. **do not exist**). Camera position lives inside the wasm heap.
- Building textures **are** fetched individually via `fetch()` from Ubisoft's CDN (`ubistatic-a.akamaihd.net/frontend/GFX_HASHED/building_lib/<sha1>.png`). This is how the collectible texture patcher works: it intercepts those fetches and returns a synthetic pink PNG for known collectible hashes. `<img>` elements are not used for game art.
- `gameevents.registerHook` exposes only coarse lifecycle triggers (`triggerLevelUp`, `triggerTutorialEnd`, `triggerFriendInvite`, `triggerClientLoaded`); not useful for game-state reading.

The long-term goal is a full automation suite: collectible highlighting, explorer/specialist dispatch, buffing, adventure management. The **Collectible Highlighter** shipped (via texture substitution). **Specialist Dispatch** is server-side end-to-end verified — the AMF3 RPC reaches GameServer, the server accepts, and specialists actually start the task. The remaining gap is that Unity's in-game UI (greyed icon + countdown bar in the star menu) only reflects the change after a zone reload; our injected `fetch` bypasses Unity's local state. See `specialist-dispatch.md` for AMF wire-format details and `log.md` for the current in-game-UI-refresh investigation.

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
      ContentView.swift         ← SwiftUI root (HSplitView + @State AppEnvironment)
      AppEnvironment.swift      ← bag of stores + BridgeSender, threaded through WebView/Router
    WebView/
      WebView.swift             ← NSViewRepresentable wrapper (takes AppEnvironment)
      WebViewCoordinator.swift  ← WKUIDelegate + WKNavDelegate + WKScriptMessageHandler
      JSInjection.swift         ← loads JS modules from bundle in injection order
      BridgeRouter.swift        ← maps InboundMessage → store mutations on env
    Bridge/
      InboundMessage.swift      ← JS→Swift message enum + Codable payloads
      OutboundMessage.swift     ← OutboundCommand protocol + DispatchSpecialist/Buff structs + JS template
      BridgeSender.swift        ← @Observable; owns weak WKWebView ref; sends OutboundCommand
    Features/
      Collectibles/
        CollectiblesStore.swift ← @Observable collectible items + map dims
      Specialists/
        SpecialistKind.swift            ← enum Explorer/Geologist/General/Unknown
        SpecialistsStore.swift          ← @Observable specialist list + duration learning
        SpecialistsPanel.swift          ← SwiftUI side panel
        SpecialistRow.swift             ← per-row View
        SpecialistTasks.swift           ← GeologistTask + ExplorerTask enums
        SpecialistTaskAvailability.swift ← TaskCode/SpecialistKind extensions (availability, defaults)
      Buffs/
        BuffsPanel.swift                ← SwiftUI side panel
        BuffsStore.swift                ← @Observable buff inventory (indexed)
        BuildingsStore.swift            ← @Observable building list (indexed by skinBase)
        BuildingCategoryRegistry.swift  ← loads building-categories.json at startup
    Utilities/
      String+CamelCase.swift            ← "PirateExplorer" → "Pirate Explorer"
      DurationFormatter.swift           ← seconds → "1d 2h 03m" / "5m 30s"
      BulkDispatcher.swift              ← sequential dispatch loop w/ 80 ms gap
    Resources/
      JS/
        bridge.js               ← window._tsoSend + window.TSOBridge
        amf3-parser.js          ← AMFParser (AMF0/AMF3 deserializer) — window._TSOAMFParser
        amf3-classifier.js      ← specialist subtype tables + classifySpec + learnFromOutbound — window._tsoClassifier
        amf3-scanner.js         ← walker + extractors + analyzeAMFBuffer — window._tsoScanner
        amf3-net.js             ← fetch/XHR wraps + auth caching + outbound capture (uses _tsoScanner)
        amf3-encoder.js         ← trait DSL + _TSORPC.dispatchSpecialist / dispatchBuff
        collectible-patcher.js  ← returns pink PNG for 55 known collectible hashes
        unity-probe.js          ← captures the Unity instance, exposes as window._tsoUnity (recon completed; see log.md)
      Data/
        collectible-hashes.json ← 55 SHA-1 hashes (substituted into patcher at load time)
        building-categories.json ← buff-panel building-group definitions
    Info.plist                  ← NSAllowsArbitraryLoads = true (game CDN needs it)
    TSOClient.entitlements      ← sandbox + network.client
```

## Architecture in one paragraph

`WebView` loads `thesettlersonline.com`. `JSInjection` installs eight JS modules at `atDocumentStart` in dependency order: **bridge.js** (sets up `window.TSOBridge` for Swift→JS and `window._tsoSend` for JS→Swift), **amf3-parser.js** (AMF0/AMF3 deserializer exposed as `window._TSOAMFParser`), **amf3-classifier.js** (specialist subtype tables + classification + outbound type-hint learning, exposed as `window._tsoClassifier`), **amf3-scanner.js** (tree walker + per-VO extractors + `analyzeAMFBuffer`, exposed as `window._tsoScanner`), **amf3-net.js** (wraps `window.fetch` and `XMLHttpRequest`, hands inbound buffers to the scanner and outbound bodies to the classifier; caches auth context in `window._tsoAuthCtx`), **amf3-encoder.js** (trait-DSL AMF3 serialiser, builds `RemotingMessage` envelopes, exposes `_TSORPC.dispatchSpecialist`/`dispatchBuff` and registers the `DISPATCH_SPECIALIST`/`DISPATCH_BUFF` TSOBridge handlers), **collectible-patcher.js** (wraps `fetch` + `XHR`; for 55 known collectible building-texture hashes returns a 32×32 hot-pink synthetic PNG so Unity renders those buildings pink in-world), **unity-probe.js** (uses a `MutationObserver` between `<script>` tags to wrap `window.createUnityInstance` and capture the Unity instance, exposing it as `window._tsoUnity`; the in-game UI refresh recon that motivated this probe concluded the JS bridge can't drive Unity's specialist UI — see `log.md`). JS→Swift uses two named `WKScriptMessageHandler` channels: `"logger"` (raw strings) and `"tso"` (structured `{type, payload}` JSON, decoded with Codable in `InboundMessage.decode`). Swift→JS goes through `BridgeSender.send(_ command: OutboundCommand)`, which JSON-encodes the payload and calls `webView.evaluateJavaScript(...)`. `BridgeRouter` maps decoded `InboundMessage` values to store mutations on the main thread via the `AppEnvironment`.

## Bridge protocol

**JS → Swift (`"tso"` handler):**
- `COLLECTIBLES` — `{mapWidth, mapHeight, items:[{gridIndex,x,y,assetName}]}`
- `GAME_STATE`   — `{state:"LOADED"|"ZONE_CHANGED"|"ZONE_LEFT", zoneId?}`
- `SPECIALISTS`  — `{items:[{uid,uid1,uid2,specialistType,subTypeId,subTypeName?,name,isIdle,skills,collectedTime?,bonusTime?,taskEndTime?,taskActionType?,taskSubTaskID?}], playerLevel?, serverTime?}`
- `BUILDINGS`    — `{items:[{gridIndex,skin,uid1,uid2,activeBuff?}]}`
- `BUFFS`        — `{items:[{uid1,uid2,buffName,resourceName,amount,insertedAt}]}`

**Swift → JS (`BridgeSender.send(_:)` with an `OutboundCommand`):**
- `DISPATCH_SPECIALIST` — `{uid1, uid2, actionType, taskCode, targetGrid}` → handled by `amf3-encoder.js`
- `DISPATCH_BUFF`       — `{buffUid1, buffUid2, targetGrid}` → handled by `amf3-encoder.js`

## Highlighting approach

Collectibles are highlighted by **texture substitution**: `collectible-patcher.js` intercepts `fetch()` and `XMLHttpRequest` calls for collectible building PNG textures (matched by SHA-1 hash against a 55-entry list in `collectible-hashes.json`) and returns a synthetic 32×32 hot-pink image instead. Unity uploads the substituted bytes as a GL texture and renders the collectible pink in-world. No overlay canvas, no calibration, no camera tracking is needed.

The canvas overlay approach was abandoned in Iteration 7 because Unity renders via its wasm heap — no JS-accessible camera globals exist.

## Key invariants

- `WebView.updateNSView` guards `webView.url == nil` — do not remove this or the game reloads on every SwiftUI state change.
- JS injection order: **bridge → amf3-parser → amf3-classifier → amf3-scanner → amf3-net → amf3-encoder → collectible-patcher → unity-probe**. The patcher must run **after** amf3-net because it wraps `window.fetch` *again* — reversing the order breaks AMF3 parsing on non-collectible URLs. amf3-scanner depends on `window._TSOAMFParser` and `window._tsoClassifier`; amf3-net depends on `window._tsoScanner`. The probe runs last; it touches only `window.createUnityInstance` / `SendMessage` so its order relative to the fetch chain doesn't matter.
- AMF3 VO trait member order is load-bearing on the wire. `amf3-encoder.js` enforces it mechanically via the `trait(cls, members)` DSL — DO NOT reorder member arrays.
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

- **In-game UI refresh on injected dispatch** — Unity's specialist icon doesn't grey out / show its countdown bar until a zone reload. Recon (2026-05-23) proved this can't be fixed from JS: Unity doesn't use the JS bridge for in-game dispatch and the wasm has no symbolic exports. Mitigated by optimistic UI in our own panel via `SpecialistsStore.markDispatched(uid:)`. See log.md "Approach 1 dead end".
- Task countdown timer in our own panel — `collectedTime` is a game-internal clock; conversion to real time is unknown.
- General dispatch auto-populated with `garrisonBuildingGridPos` (user must enter grid manually for now).
- Buff management, adventure features, trading, building automation.
- Persistent storage of dispatch templates or any app settings.
- Unit or UI tests.
