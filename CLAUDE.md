# TSOClient — Claude context

## What this project is

A native macOS wrapper around The Settlers Online (TSO), built as an automation and enhancement platform. The game runs inside a `WKWebView`. The current TSO client is a **Unity WebGL** build (the original Flash client was retired with Flash itself; a brief HTML5 era preceded Unity). The backend protocol is unchanged — GameServer responses are still AMF3/Flex over `fetch`, which is why the AMF3 scanner keeps working. Behaviour is extended through injected JavaScript that intercepts network responses and substitutes textures. Swift owns the native chrome, data models, dispatch coordination, and panel UI; JavaScript owns in-page interception, AMF3 parsing/encoding, and texture patching.

**Unity-client implications** (do not relearn each session):
- The game canvas is a single WebGL2 context; there is no JS-accessible game state (`window.s_oIsland` / `s_oMain` / `s_oGame` etc. **do not exist**). Camera position lives inside the wasm heap.
- Building textures **are** fetched individually via `fetch()` from Ubisoft's CDN (`ubistatic-a.akamaihd.net/frontend/GFX_HASHED/building_lib/<sha1>.png`). This is how the collectible texture patcher works: it intercepts those fetches and returns a synthetic pink PNG for known collectible hashes. `<img>` elements are not used for game art.
- `gameevents.registerHook` exposes only coarse lifecycle triggers (`triggerLevelUp`, `triggerTutorialEnd`, `triggerFriendInvite`, `triggerClientLoaded`); not useful for game-state reading.
- **In-game UI does not refresh on injected dispatch.** Unity is locally authoritative for the star-menu specialist icon: the in-game click handler updates wasm state *before* the network call. Our injected `fetch` reaches the server (specialist actually starts the task), but Unity has no reason to repaint until the next zone reload. This is **structurally unfixable from JS** — see "Unity UI refresh dead end" below.

**Shipped automation:**
- **Collectible Highlighter** — texture substitution renders all 55 collectible types pink in-world.
- **Specialist Dispatch** — manual one-shot dispatch + per-kind bulk dispatch + per-row optimistic UI flip. AMF3 RPC reaches GameServer end-to-end.
- **Specialist Auto-Loop** — Explorer loop (per-uid wake-up timer driven by predicted duration) and per-subtype Geologist loops (Stone Cold / Diligent), persisted across launches via `UserDefaults`.
- **Buff Manager** — buff inventory + buildings panel grouped by category (Mines / Masons / Smelters / Wood / Food / Other), per-group buff selection, master "Buff all" override.
- **Player buff auto-detection** — Prestigious Friend Buff (PFB, ×0.8 task time) detected from `dZoneVO.zoneBuffs` and folded into every duration estimate.
- **Idle sleep inhibitor** — keeps the app awake while auto-loops run (`ProcessInfo.beginActivity`).

**What a collectible is:** a resource item (herbs, banner, food cart, etc.) that spawns at a random map tile on the player's island and is picked up by clicking. *Not* a building, and *not* the per-building "ready to collect" stockpile (`dPersistedPickupItemVO`). The feature mirrors what the **Pinky** Chrome extension and the Windows AIR client (`fedorovvl/tso_client`) do for the same game.

## Important reference files

- `amf-vo-keys.md` — captured key reference for `dPlayerVO` and `dZoneVO` (the two top-level VOs on every zone-load response). Consult before adding features that need zone-level data instead of re-deriving from a fresh capture.
- `building-skins.md` — canonical raw `skin` strings used by `building-categories.json`.

## Where to find things

| Concept | Path |
|---|---|
| App entry + root view | `TSOClient/App/` |
| WKWebView wrapper + coordinator + JS injection | `TSOClient/WebView/` |
| Swift↔JS protocols, dispatcher, per-message handlers | `TSOClient/Bridge/` |
| Collectibles data model | `TSOClient/Features/Collectibles/` |
| Specialists data model, panel UI, dispatch coordinator, auto-loop strategies | `TSOClient/Features/Specialists/` |
| Buffs data model, panel UI, buff dispatch coordinator | `TSOClient/Features/Buffs/` |
| Cross-cutting utilities (logger, KV store, resource loader, naming registry, sleep inhibitor) | `TSOClient/Utilities/` |
| Injected JavaScript source files | `TSOClient/Resources/JS/` |
| Data resources (collectible hashes, building/buff categories, duration tables, naming) | `TSOClient/Resources/Data/` |

## Repo layout

```
TSOClient/                      ← Xcode project root
  TSOClient.xcodeproj/
  TSOClient/                    ← source root (synchronized folder group — no pbxproj edits needed)
    TSOClientApp.swift          ← @main, window 1280×900, starts SleepInhibitor
    App/
      ContentView.swift         ← SwiftUI root (HSplitView + tabbed side panel)
      AppEnvironment.swift      ← composition root: wires stores, executor, sender, dispatcher, coordinators
    WebView/
      WebView.swift             ← NSViewRepresentable wrapper (narrow deps: executor, inbound, logger)
      WebViewCoordinator.swift  ← WKUI/Nav/ScriptMessage handler; routes inbound to InboundDispatcher
      JSInjection.swift         ← loads JS modules from bundle in dependency order
      JSModule.swift            ← single injected module (name + optional source pre-processor)
    Bridge/
      InboundMessage.swift          ← namespace of Decodable payload structs (data only, no dispatch)
      InboundMessageHandler.swift   ← protocol: one handler per inbound `type` string
      InboundDispatcher.swift       ← registers handlers, decodes payload bytes, calls handler
      CollectiblesHandler.swift     ← per-type handler files (one each)
      SpecialistsHandler.swift      ← (also kicks off auto-loop sweeps post-apply)
      BuildingsHandler.swift
      BuffsHandler.swift
      PlayerBuffsHandler.swift      ← PFB auto-detection sink
      GameStateHandler.swift        ← LOADED/ZONE_CHANGED/ZONE_LEFT; clears ZoneLifecycle conformers
      ZoneLifecycle.swift           ← protocol: stores that get wiped on ZONE_LEFT
      WireCommand.swift             ← protocol for outbound commands (Encodable + `type`)
      OutboundMessage.swift         ← DispatchSpecialistCommand / DispatchBuffCommand structs
      WireCommandJSSerializer.swift ← renders a WireCommand as a TSOBridge.receive JS expression
      JSExecutor.swift              ← protocol for evaluating JS; WKWebViewJSExecutor is the prod conformer
      BridgeSender.swift            ← @Observable; serializes WireCommand → JS, hands to executor
      DispatchPorts.swift           ← SpecialistDispatchPort + BuffDispatchPort (domain seams over BridgeSender)
    Features/
      Collectibles/
        CollectiblesStore.swift     ← @Observable collectible items + map dims
      Specialists/
        SpecialistKind.swift            ← enum Explorer/Geologist/General/Unknown
        SpecialistKindPolicy.swift      ← per-kind policy (default task, label, availability)
        SpecialistItem.swift            ← per-row VO + SpecialistSkill
        SpecialistsStore.swift          ← @Observable items + playerLevel + pfbActive; learner lives inside
        SpecialistsDiffer.swift         ← apply(next:to:) — touch only changed indices when id sequence matches
        SpecialistsPanel.swift          ← SwiftUI side panel (filter chips, bulk, auto-loop sections, list)
        SpecialistRow.swift             ← per-row View (status badge, countdown, task picker)
        SpecialistTasks.swift           ← TaskCode + GeologistTask + ExplorerTask + GeologistAutoLoopSubtype
        SpecialistTaskAvailability.swift← TaskCode/SpecialistItem extensions (delegate to policy)
        SpecialistDispatchCoordinator.swift ← @Observable view-model: selection state, bulk dispatch, auto-loop facade
        AutoLoopStrategy.swift          ← protocol + ExplorerAutoLoopStrategy + GeologistAutoLoopStrategy
        SpecialistsAutoLoopRunner.swift ← narrow protocol the handler sees (runAutoExplorerLoop / runAutoGeologistLoop)
        SpecialistDurationLearner.swift ← tracks busy/idle transitions, persists learned totals
        SpecialistDurationLogger.swift  ← formats [ExplorerDuration]/[GeologistDuration] log lines + divergence
        SpecialistDurationLookup.swift  ← read-only window the row depends on (taskStartedAt, learnedDuration)
        SpecialistDisplayFormatter.swift← subtype → label via NamingRegistry; compact "Name (Subtype)" for logs
        DurationEstimator.swift         ← protocol; RegistryDurationEstimator delegates to ExplorerDurationRegistry
        ExplorerDurationRegistry.swift  ← loads explorer-durations.json (base + bonus + skill effects)
      Buffs/
        BuffsStore.swift                ← @Observable buff inventory (indexed by buffName)
        BuildingsStore.swift            ← @Observable buildings (indexed by skinBase)
        BuildingCategoryRegistry.swift  ← loads building-categories.json
        BuildingSkinNormalizer.swift    ← strips trailing "_NN" variant suffix from a raw skin
        BuffCategoryClassifier.swift    ← data-driven prefix/exact match per BuffCategory (from buff-categories.json)
        BuffDispatchCoordinator.swift   ← @Observable view-model: per-category selection, master override, bulk buff loop
        BuffsPanel.swift                ← SwiftUI side panel (grouped by BuildingGroup, master row, per-category rows)
    Utilities/
      Logger.swift                ← protocol + os.Logger-backed ConsoleLogger (avoids print's global mutex)
      KeyValueStore.swift         ← protocol + UserDefaultsKeyValueStore (auto-loop persistence seam)
      ResourceLoader.swift        ← protocol + BundleResourceLoader (registry loading seam)
      NamingRegistry.swift        ← loads naming.json (specialist subtype / buff / building human-readable names)
      SleepInhibitor.swift        ← ProcessInfo.beginActivity wrapper (idle display + system sleep)
      BulkDispatcher.swift        ← BulkDispatching protocol + 80 ms-gap sequential runner
      DurationFormatter.swift     ← seconds → "1d 2h 03m" / "5m 30s"
      String+CamelCase.swift      ← "PirateExplorer" → "Pirate Explorer"
    Resources/
      JS/                         ← see "JS module roster" below
      Data/
        collectible-hashes.json   ← 55 SHA-1 hashes (substituted into patcher at load time)
        building-categories.json  ← buff-panel building-group definitions
        buff-categories.json      ← prefix/exact match rules per BuffCategory
        explorer-durations.json   ← base duration + subtype timeBonus + skill effects (for explorer auto-loop ETA)
        geologist-durations.json  ← scaffolded; durations TBD by observation
        naming.json               ← human-readable display overrides
    Info.plist                    ← NSAllowsArbitraryLoads = true (game CDN needs it)
    TSOClient.entitlements        ← sandbox + network.client
```

## Architecture in one paragraph

`WebView` loads `thesettlersonline.com/en/play`. `JSInjection` installs the JS modules listed below at `atDocumentStart`. JS→Swift uses two named `WKScriptMessageHandler` channels: `"logger"` (raw strings, prefixed `[JS]`) and `"tso"` (structured `{type, payload}` JSON). `WebViewCoordinator` hands `"tso"` messages to `InboundDispatcher` on the main thread; the dispatcher looks up the handler registered for that `type` string, serializes the payload via `JSONSerialization` (skipped entirely if no handler is registered), and the handler decodes it with `JSONDecoder` and applies it to its store. `AppEnvironment` is the composition root — it builds every store, the `WKWebViewJSExecutor`, the `BridgeSender`, the dispatch coordinators, registers every handler on the `InboundDispatcher`, and is held by `ContentView` as a single `@State`. Swift→JS goes through `BridgeSender.send(_ command: WireCommand)`: `DefaultWireCommandJSSerializer` encodes the command's Encodable payload to JSON, wraps it in an IIFE that calls `window.TSOBridge.receive(...)`, and the `JSExecutor` evaluates it on the `WKWebView`. Coordinators (`SpecialistDispatchCoordinator`, `BuffDispatchCoordinator`) depend on the narrow `SpecialistDispatchPort` / `BuffDispatchPort` protocols rather than `BridgeSender` directly.

## JS module roster

Injection order is dependency-ordered; everything runs at `atDocumentStart`.

| Module | Globals exposed | Role |
|---|---|---|
| `bridge.js` | `window.TSOBridge`, `window._tsoSend`, `window._tsoTs`, `window._tsoDiag`, `window._tsoDiagLog` | Swift↔JS message plumbing + gated diagnostic logger |
| `amf3-parser.js` | `window._TSOAMFParser` | AMF0/AMF3 deserializer |
| `amf3-classifier.js` | `window._tsoClassifier` | Specialist subtype tables (Explorer/Geologist/General) + `classifySpec` + `learnFromOutbound` (watches game's own type=95 dispatches to learn types) |
| `amf3-scanner.js` | `window._tsoScanner` | Tree walker + per-VO extractors; emits COLLECTIBLES / SPECIALISTS / BUILDINGS / BUFFS / PLAYER_BUFFS / GAME_STATE |
| `amf3-net.js` | (wraps `fetch` + `XMLHttpRequest`) | Hands inbound buffers to the scanner, outbound bodies to the classifier; caches auth in `window._tsoAuthCtx`, tracks `window._tsoLastSeq` |
| `amf3-encoder.js` | `window._TSORPC`, registers `DISPATCH_SPECIALIST` / `DISPATCH_BUFF` handlers | Trait-DSL AMF3 serializer; builds `RemotingMessage` envelopes for outbound RPC |
| `collectible-patcher.js` | (wraps `fetch` + `XHR` *again*) | Returns synthetic 32×32 hot-pink PNG for the 55 known collectible building-texture hashes |
| `unity-probe.js` | `window._tsoUnity`, `window._tsoUnityProbe` | Captures the Unity instance via a `MutationObserver`; recon completed (see "Unity UI refresh dead end"); not load-bearing today |

## Bridge protocol

**JS → Swift (`"tso"` handler):**
- `COLLECTIBLES`  — `{mapWidth, mapHeight, items:[{gridIndex,x,y,assetName}]}`
- `GAME_STATE`    — `{state:"LOADED"|"ZONE_CHANGED"|"ZONE_LEFT", zoneId?}`
- `SPECIALISTS`   — `{items:[{uid,uid1,uid2,specialistType,subTypeId,subTypeName?,name,isIdle,skills,collectedTime?,bonusTime?,taskEndTime?,taskActionType?,taskSubTaskID?}], playerLevel?}`
- `BUILDINGS`     — `{items:[{gridIndex,skin,uid1,uid2,activeBuff?}]}`
- `BUFFS`         — `{items:[{uid1,uid2,buffName,resourceName,amount,insertedAt}]}`
- `PLAYER_BUFFS`  — `{pfbActive: bool}` (auto-detected from `dZoneVO.zoneBuffs`)

**Swift → JS (`BridgeSender.send(_ command:)`):**
- `DISPATCH_SPECIALIST` — `{uid1, uid2, actionType, taskCode, targetGrid}` → handled by `amf3-encoder.js`
- `DISPATCH_BUFF`       — `{buffUid1, buffUid2, targetGrid}` → handled by `amf3-encoder.js`

## AMF3 wire format (specialist dispatch)

`amf3-encoder.js` enforces VO trait member order via the `trait(cls, members)` DSL. Member order is **load-bearing on the wire** — AMF3 trait registration is order-dependent. Don't reorder.

**AMF0 envelope:** version `00 03`, 0 headers, 1 body, target=`"null"` (string literal, not a service method), response=`"/N"` (mirrors `window._tsoLastSeq`), body=AMF0 type `0x11` (AMF3 switch) → Array containing one `RemotingMessage`.

**`flex.messaging.messages.RemotingMessage` — 13 members in order:**
`source="com.bluebyte.game.servlet.EventHandler"`, `operation="ExecuteServerCall"`, `parameters=null`, `remoteUsername=null`, `remotePassword=null`, `correlationId=null`, `body=[dServerCall]`, `clientId=null`, `destination="SMC"`, `headers={__class:"", DSEndpoint:"SMC-Endpoint", DSId:<session-uuid>}`, `messageId=<new UUID>`, `timestamp=0`, `timeToLive=0`.

**`dServerCall` — 6 members:** `type, zoneID, data, dsoAuthUser, dsoAuthToken, dsoAuthRandomClientID`. For specialist dispatch, `type=95` (StartSpecialistTask). `dsoAuthUser`, `dsoAuthToken`, `dsoAuthRandomClientID`, `zoneID`, `DSId` are sniffed from any outbound game POST by `cacheAuthCtx` in `amf3-net.js` and stored on `window._tsoAuthCtx`.

**`dServerAction` — 4 members:** `type, grid, endGrid, data`. `type` = task category (see below). `grid` = 0 for Geologist/Explorer; garrison grid for Generals. `endGrid` = 0 for all non-General tasks.

**`dStartSpecialistTaskVO` — 3 members:** `uniqueID, subTaskID, paramString`. `uniqueID` is a `dUniqueID { uniqueID1, uniqueID2 }` composite. `paramString=null`.

**`credentials: 'omit'` is required.** Server uses wildcard `Access-Control-Allow-Origin: *`, which forbids credentialed requests. Body-level `dsoAuthToken` is the sole auth mechanism.

### Task codes

| Specialist | `dServerAction.type` | `subTaskID` | Tasks |
|---|---|---|---|
| Geologist | 0 | 0–8 | Stone / Copper / Marble / Iron / Gold / Coal / Granite / Titanium / Salpeter |
| Explorer  | 1 | 0–6 | Treasure: Short / Medium / Long / VeryLong / Erudite / Colada / Longest (note: 4=Erudite, 5=Colada, 6=Longest) |
| Explorer  | 2 | 0–3 | Adventure: Short / Medium / Long / VeryLong |
| General   | 12 | 0 | Send to Star Menu (grid = garrison grid index) |

Explorer skill gates: skill ID 39 (`TravellingErudite`) unlocks `1,4`; skill ID 40 (`BeanACollada`) unlocks `1,5`. Other observed Explorer skill IDs: 23 Pilgrimage, 24 MountainBoots, 28 ExtendedWeekend, 35 Sabbatical, 36 Pathfinder, 41 FearlessHiker. Geologist level gates per `GeologistTask.minLevel` (Stone=0, Copper=9, Marble=19, Iron=20, Gold=23, Coal=24, Granite=60, Titanium=61, Salpeter=62).

## Specialist VO field inventory

`dSpecialistVO` raw fields:
`playerID, specialistType, name_string, currentHitPoints, faceType, xp, diceBonus, retreatThreshold, task, garrisonBuildingGridPos, xpProduced, battlesWon, unitsDefeated, buildingsDestroyed, skills, eventSkills, uniqueID, insertedAt, armyVO`.

| Field | Semantics |
|---|---|
| `specialistType` | Numeric subtype enum. Basic: 0=General, 1=Explorer, 2=Geologist. Premium variants have higher IDs (tables in `amf3-classifier.js`). |
| `task` | Active task VO when busy; `null` when idle. `dSpecialistTask_FindDepositVO` → Geologist; `dSpecialistTask_FindTreasureVO` / `dSpecialistTask_FindEventZoneVO` → Explorer. |
| `garrisonBuildingGridPos` | ≥0 for Generals (their garrison grid); −1 for all Explorers and Geologists. **Authoritative General indicator.** |
| `armyVO` | Present on ALL 52 specialists regardless of type. Do NOT use for classification. |
| `name_string` | Player's custom name. Fallback classifier only. |
| `uniqueID.uniqueID1/2` | Dispatch identifiers. |
| `insertedAt` | Unix timestamp of specialist creation (stable ID across sessions). |
| `collectedTime` | Elapsed time since task start in **base-time-equivalent milliseconds** — ticks at `bonus/100 × wall clock`. Real elapsed sec = `ct/1000 × 100/bonus`. Counts UP. **No total-duration or end-time field exists on the wire** — total duration comes from `ExplorerDurationRegistry` (game-config-equivalent). |
| `bonusTime` | Observed 0 in samples; not currently consumed. |

`isIdle: taskObj === null`. Busy → task VO non-null → button disabled, countdown shown. Idle → task null → green "Idle" badge.

### Classification strategy (`amf3-classifier.js` + `amf3-scanner.js`)

Priority order:
1. `garrisonBuildingGridPos >= 0` → **General** (authoritative).
2. `_tsoSpecTypeHints[uid]` → type learned from (a) game's own outbound type=95 dispatches (`learnFromOutbound`), or (b) task VO class observed in any previous zone load.
3. Task VO class name → **Geologist** (FindDeposit) or **Explorer** (FindTreasure / FindEventZone).
4. Numeric subtype tables (EXPLORER_TYPES / GEOLOGIST_TYPES / GENERAL_TYPES).
5. `specialistType` ∈ {0,3} → General.
6. `name_string` keyword match.
7. Default: **Explorer** (most premium drops are explorers). Unknown numeric IDs are logged so the tables can be extended.

Hints are persisted on `window._tsoSpecTypeHints` so idle specialists (task=null) classify correctly on the next zone load.

## Duration estimation

`ExplorerDurationRegistry.estimate(task:subTypeId:skills:pfbActive:)` replicates fedorovvl/tso_client's `user_exp_time_matrix.js`:
```
t = baseDurations[task]
for each skill with level>0 where scope matches task:
    t *= (1 - reduction[level-1]/100)
t *= 100 / timeBonus[subTypeId]
if pfbActive:  t *= 0.8                      // Prestigious Friend Buff (20% reduction)
```
Tables live in `explorer-durations.json` (loaded once via `ResourceLoader`). PFB is auto-detected by `amf3-scanner.js` from `dZoneVO.zoneBuffs` (any `dPersistedBuffApplianceVO` whose `buffID` matches the PFB family; numeric `buffID=663`=15-day variant confirmed); the detection result rides on the `PLAYER_BUFFS` message and lands in `SpecialistsStore.pfbActive`. The panel toggle is a manual override that the next inbound payload reasserts.

The geologist counterpart `geologist-durations.json` is scaffolded with `timeBonus` per subtype but the base-duration table is TBD — populate by observation. Hence: **geologist auto-loops do not arm a per-uid wake-up timer** (no reliable ETA), they only re-fire on the next `SPECIALISTS` payload (zone reload or game-emitted refresh).

`SpecialistDurationLearner` tracks every busy→idle transition: observed real-time duration is written to `learnedDurations[subTypeId:actionType:subTaskId]`, persisted to `UserDefaults`, and a divergence log line fires when the registry estimate disagrees by >5% (surfaces missing skill mappings / wrong `timeBonus` entries).

## Auto-loop architecture

`SpecialistDispatchCoordinator` owns the auto-loop state machine. The work itself is pluggable via `AutoLoopStrategy`:

- **`ExplorerAutoLoopStrategy`** — claims idle explorers when the toggle is on and they can run `autoExplorerLoopTask`. After every dispatch, arms a per-uid wake-up `Task` that fires at `estimator.estimate(...) + autoReDispatchBuffer (default 8 s)` seconds and re-dispatches the same uid. Lets the loop keep running mid-session without waiting for the next `SPECIALISTS` payload.
- **`GeologistAutoLoopStrategy`** — one per supported subtype (`GeologistAutoLoopSubtype.supported`: Stone Cold = 35, Diligent = 59). Returns `nil` from `reDispatchDelay` so the loop only re-fires on the next inbound `SPECIALISTS` payload. Each subtype has its own toggle + task picker, so e.g. Stone Cold can loop Granite while Diligent loops Gold.

Strategies are registered by id (`auto-loop-explorer`, `auto-loop-geologist-<subTypeId>`); `runAutoExplorerLoop()` / `runAutoGeologistLoop()` are thin facades that look the strategy up. Adding a new auto-loop kind = new conformer + register call. Toggle state is persisted via `KeyValueStore`.

## Collectibles & highlighting

Highlighting uses **texture substitution**: `collectible-patcher.js` intercepts `fetch()` and `XMLHttpRequest` calls for collectible building PNG textures (matched by SHA-1 hash against the 55-entry list in `collectible-hashes.json`, sourced from `perceptron8/pinky.ext` `live.json`) and returns a synthetic 32×32 hot-pink PNG. Unity uploads the substituted bytes as a GL texture and renders the collectible pink in-world. No overlay canvas, no calibration, no camera tracking needed.

Collectibles in the AMF tree are `dBuildingVO` instances whose `buildingName_string` (or `skin`) starts with `"Collectible"`. Position: `buildingGrid` flat index → `gridX = gi % mapWidth`, `gridY = floor(gi / mapWidth)`. Map dims come from `dZoneVO.mapWidth × dZoneVO.mapHeight` (observed 89×196).

Pickup signal: `DestructBuildingResultVO.gridIndex`. Pickup responses have `ctx.allBuildings.length === 0`; the scanner handles destruct early — do NOT call `setCollectibles([])` on this branch. Settings endpoint (`r03-ls.thesettlersonline.com/settingsdefine…`) carries zero buildings/maps and is filtered.

GameServer realm: `https://r03-gs003.thesettlersonline.com/GameServer/amf` (sniffed live; `amf3-net.js` updates `window._tsoRealmUrl` on every observed request so zone-shard changes are picked up automatically).

## Key invariants

- `WebView.updateNSView` guards `webView.url == nil` — do not remove this or the game reloads on every SwiftUI state change.
- JS injection order: **bridge → amf3-parser → amf3-classifier → amf3-scanner → amf3-net → amf3-encoder → collectible-patcher → unity-probe**. The patcher must run **after** amf3-net because it wraps `window.fetch` *again* — reversing the order breaks AMF3 parsing on non-collectible URLs. amf3-scanner depends on `_TSOAMFParser` + `_tsoClassifier`; amf3-net depends on `_tsoScanner`. unity-probe touches only `window.createUnityInstance` so its order relative to the fetch chain doesn't matter.
- AMF3 VO trait member order is load-bearing on the wire. `amf3-encoder.js` enforces it mechanically via the `trait(cls, members)` DSL — DO NOT reorder member arrays.
- `WKUserContentController.add(_:name:)` retains the handler — `WebViewCoordinator` is `NSObject`, no extra wrapper needed.
- `@Observable` (Swift 5.9 macro, not `ObservableObject`). Use `@State` at the owner site; the class reference propagates automatically.
- `BridgeSender` does NOT hold a `WKWebView`. It depends on `JSExecutor`; the concrete `WKWebViewJSExecutor` is created in `AppEnvironment` and the actual `WKWebView` is late-bound inside `WebView.makeNSView` (so the sender exists before the view does).
- Coordinators depend on **ports** (`SpecialistDispatchPort`, `BuffDispatchPort`), the learner exposes a **lookup** (`SpecialistDurationLookup`), the handler sees a **runner** (`SpecialistsAutoLoopRunner`), and the row's countdown reads through a **`DurationEstimator`**. These narrow seams exist so a unit test can swap a fake at the relevant boundary without spinning up the whole environment.
- Resource registries (`NamingRegistry`, `BuildingCategoryRegistry`, `BuffCategoryClassifier`, `ExplorerDurationRegistry`) load via `ResourceLoader`. Missing JSON files log and fall back to empty — production callers use the `.default` static.

## Unity UI refresh dead end (reconnaissance done — do not re-investigate)

**There is no JS-side way to make Unity repaint the specialist icon / countdown bar after an injected dispatch.** Unity is locally authoritative: its in-game click handler updates wasm state *before* firing the network call. Our injection skips the click handler, so the network call lands but Unity has no reason to repaint. The icon catches up on the next zone reload.

What was tried:
- `unity-probe.js` wraps `window.createUnityInstance` and exposes the Unity instance as `window._tsoUnity`. `SendMessage`, `Module.ccall`, `Module.cwrap`, `Module._SendMessage*` are all reachable.
- Clicking the in-game dispatch button produces **zero `SendMessage` calls** — Unity handles the click entirely in wasm. The JS bridge is one-way (host→Unity); the in-game UI never traverses it.
- **Module exports are stripped** — no `_Specialist*` / `_Refresh*` / `_Zone*` / `_Update*` symbols. Only Emscripten standard exports + the three `_SendMessage*` variants. Nothing useful to `ccall`.
- Manual in-game dispatch emits a single `type=95 actionType=0` — byte-identical to ours. No follow-up refresh opcode exists.

**Mitigation in place:** `SpecialistsStore.markDispatched(uid:)` flips `isIdle` and seeds `taskActionType`/`taskSubTaskId` optimistically; our panel reflects the dispatch immediately. The in-game UI remains stale until the next zone reload. Accepted limitation.

## False leads — do not revisit

| Approach | Why ruled out |
|---|---|
| Iso-diamond formula `(gx-gy, gx+gy)` | AMF coords are already screen-aligned. |
| Overlay canvas + camera tracking | Superseded by texture substitution; Unity has no JS-accessible camera globals. |
| `jsOverlay`, `jsURLRewriter`, `tso-asset://` scheme | Disabled; Unity doesn't use `<img>` for building sprites. |
| XHR-only texture interception | Unity loads building textures via `fetch()`. |
| Sprites from GL atlas | Wrong — individual per-building fetches from CDN. |
| `sendServerAction(opcode, …)` as top-level AMF3 args | Wrong. Envelope is Array containing `RemotingMessage` wrapping `dServerCall`. Target = `"null"`. |
| `dStartSpecialistTaskVO` fields: `specialistUID`, `task`, `depositGridPos`, `duration` | Wrong. Actual: `uniqueID`, `subTaskID`, `paramString`. |
| `dSpecialistVO` fields: `name`, `level`, `skillLevel`, `currentTask`, `taskEndTime` | Wrong. Actual: `name_string`, `specialistType` (numeric), `task` (VO or null), `uniqueID`. No `level` field. |
| `armyVO` presence → General | Wrong. `armyVO` is on ALL specialists. Use `garrisonBuildingGridPos >= 0`. |
| `specialistType` 1=Geologist, 2=Explorer, 3=General | Wrong. Live data: 1=Explorer, 2=Geologist; 0/3=General; higher IDs = premium variants. |
| `isIdle: taskObj !== null` | Wrong. `task` is null for idle. Correct: `isIdle: taskObj === null`. |
| `credentials: 'include'` in fetch | CORS failure — server uses wildcard `Allow-Origin: *`. Use `'omit'`. |
| Response counter always `/1` | Wrong — server may reject mid-session replays. Counter mirrors `_tsoLastSeq` from the game's own requests. |
| In-game UI refresh via `unityInstance.SendMessage` or wasm `ccall` | Unity doesn't use the JS bridge for in-game dispatch. Wasm has no symbolic exports. |
| In-game UI refresh via a server-side refresh opcode | Manual in-game dispatch sends only `type=95 actionType=0` — identical to ours. Unity updates UI locally *before* the network call. |
| `collectedTime` as remaining-time clock | Wrong. It's elapsed ms since task start, ticking at `bonus/100 × wall clock`. Remaining-time display needs a base-duration lookup (registry). |
| Geologist subTaskID 7 label "Alloy Ore" | In-game label is **Titanium**. fedorovvl uses `FindDepositAlloyOre` for the same code. |

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
- **JS debugging**: add `webkit.messageHandlers.logger.postMessage(...)` calls freely; they stream to Xcode console with `[JS]` prefix. Or set `window._tsoDiag = true` from Safari Web Inspector to enable the gated `_tsoDiagLog` traces. Never remove the `"logger"` handler registration.
- **JS files**: edit `Resources/JS/*.js` directly. No recompile needed to change JS logic — only a re-run.

## What does NOT exist yet

- **In-game UI refresh on injected dispatch** — structural Unity limitation (see "Unity UI refresh dead end"). Mitigated by optimistic UI in our own panel.
- **Geologist task ETA / countdown** — `geologist-durations.json` base-duration table is unpopulated. Auto-loop relies on zone-reload re-fires until a duration model exists. Populate by observation.
- **General dispatch auto-populated `garrisonBuildingGridPos`** — value is on `dSpecialistVO` but not threaded into `SpecialistItem`; user enters grid manually.
- **Adventure features, trading, building/production automation.**
- **Unit or UI tests.** Architecture is set up for them (narrow protocols at every seam) but no test target exists yet.
