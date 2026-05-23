 Specialist Dispatch — Next Milestone                                                                                                             
                                                                                                                                                
Context

 The Collectible Highlighter shipped via texture substitution (jsCollectiblePatcher). The next feature is Specialist Dispatch — list the player's
  explorers / geologists / generals in a native side panel, select one, and dispatch a task with one click. This mirrors the most-used feature in
  fedorovvl/tso_client (the geologist/explorer mass-dispatch + generals manager).

 The hard part is not the UI; it's that the project currently has no outbound AMF3 capability. The scanner parses incoming responses but never
 sends anything to GameServer. Specialist Dispatch needs one new RPC primitive — an analogue of the AIR client's game.gi.SendServerAction(opcode,
  p1, p2, p3, vo) — implemented from scratch in JS, with cookies/session piggybacking on the live game's existing fetch.

 Once that primitive exists, every other Group-1 feature from the catalog (mass-buffing, batch trade, drunken miner, etc.) becomes a thin layer
 on top.

 CLAUDE.md is also stale — it describes a 4-module overlay architecture that was abandoned in Iteration 7. This milestone also corrects it.

 ---
 Current state (verified by reading source)

 - Injected JS modules (ContentView.swift:21-33): jsBridge, jsAMF3Scanner, jsCollectiblePatcher. jsOverlay and jsURLRewriter are commented out.
 - Scanner (ContentView.swift:769-1526): wraps window.fetch and XMLHttpRequest.open/send. Captures responses only. Parses AMF3 envelope, walks
 object tree, extracts dBuildingVO/Collectible*, sends COLLECTIBLES to Swift. Also indexes dSpecialistVO, dDepositVO, dPersistedBuffApplianceVO
 into ctx.classes but doesn't surface them.
 - Patcher (ContentView.swift:1583-1837): wraps fetch + XHR request side. For 55 known collectible PNG hashes, returns a 32×32 pink synthetic
 response. Has no general "send arbitrary AMF" capability — only intercept-and-substitute.
 - Bridge (ContentView.swift:140-164): _tsoSend(type, payload) (JS→Swift), window.TSOBridge.receive({type, payload}) (Swift→JS). Two
 WKScriptMessageHandler channels: logger, tso.
 - Swift models: CollectiblesStore (@Observable), BridgeProtocol.swift (Inbound: COLLECTIBLES/GAME_STATE/CALIBRATION_DONE; Outbound:
 SET_OVERLAY/SET_OVERLAY_COLOR/RENDER/CALIBRATE — all dead overlay-era cases).
 - UI: ContentView is WebView(...).frame(minWidth: 1024, minHeight: 768) — no chrome.
 - HighlightSchemeHandler + CollectiblesHighlighter.swift still registered for tso-asset://; dormant under Unity. Not in the way; leave alone.
 - GameServer endpoint observed: https://r03-gs003.thesettlersonline.com/GameServer/amf (per log.md).

 ---
 Strategy

 Outbound RPC: capture-then-replay, not encode-from-spec. Building an AMF3 encoder from the spec alone is risky — the Flex envelope has quirks
 (target name conventions, response-counter strings, class trait order) that are easier to learn by observing one real SendServerAction request
 and using that as a template.

 So Phase 1 is passive sniffing of an outbound request the player makes manually (dispatching one geologist by hand). Phases 2+ build the encoder
  around the bytes we capture.

 MVP first, templates later. Ship single-specialist single-task dispatch end-to-end first. Multi-select, JSON templates, batch dispatch with
 throttling come in a follow-up milestone — they're pure UX on top of the verified primitive.

 ---
 Implementation plan

 Phase 1 — Outbound traffic capture (diagnostics only, ~30 min)

 Extend jsAMF3Scanner to log outbound POST bodies to GameServer/amf as hex dumps + parsed AMF3 trees. No game-modifying code in this phase.

 - Hook XMLHttpRequest.prototype.send to read the body argument when URL contains GameServer. Hex-dump first 512 bytes.
 - Hook window.fetch request side: if init.body is an ArrayBuffer/Uint8Array/Blob, hex-dump it.
 - Re-parse outbound body through the existing AMFParser (envelope branch) and pretty-print the AMF3 tree to the logger channel.

 Verification: Run app, manually dispatch a geologist on a deposit-finding task. Console should show one [AMF3:out] block with the envelope. From
  it, identify:
 1. Target string (likely "RemoteService.SendServerAction" or similar Flex naming)
 2. Response counter format (Flex uses /<n> like /3, /4, …)
 3. Argument shape: (opcode=95, subtask=12, target=?, ?, dStartSpecialistTaskVO{…})
 4. Exact field set of dStartSpecialistTaskVO — cross-reference against the AS3 source pattern in fedorovvl/tso_client userscripts
 (user_geo_dispatcher.js, user_explorer_dispatcher.js).

 Files touched: ContentView.swift only (extend jsAMF3Scanner).

 Phase 2 — AMF3 encoder + envelope writer (~1 day)

 Mirror of AMFParser. New JS module jsAMF3Encoder (insert after jsAMF3Scanner):

 - Primitives: writeU8, writeU16BE, writeS32BE, writeF64BE, writeU29 (variable-length), writeUTF8.
 - AMF3 value writers: undefined/null/bool/int/double/string (with string ref table) / array / object (with trait registration + ref table).
 - Externalizable bypass: only flex.messaging.io.ArrayCollection needs source re-emission for our outbound case.
 - AMF0 envelope writer: version 00 03, header count 00 00, body count 00 01, target+response+body-length-prefixed AMF0 wrapper around the single
  AMF3-typed argument.
 - Round-trip test (in a JS scratch block, log-only): parse the Phase-1-captured bytes, re-encode through the new writer, assert byte-equality.
 Iterate until equal.

 Files touched: ContentView.swift only.

 Phase 3 — sendServerAction(opcode, p1, p2, p3, vo) primitive (~half day)

 A JS function that:
 1. Auto-discovers the realm URL from the first observed GameServer/amf request (cache it in module scope).
 2. Auto-increments a response counter per call.
 3. Builds the envelope using the Phase-2 encoder.
 4. POSTs via fetch with credentials: 'include', Content-Type: application/x-amf, ArrayBuffer body.
 5. Returns a Promise resolving to the parsed response AMF3 value (reuse AMFParser).

 Add a Swift→JS bridge message RPC_SEND (low-level escape hatch for testing) and a dedicated DISPATCH_SPECIALIST for the typed case.

 Verification: From the Safari Web Inspector console, call window._TSORPC.sendServerAction(95, 12, target, 0, voPayload) with a hand-built VO.
 Confirm the in-game specialist starts the task. This is the go/no-go gate for the whole milestone.

 Files touched: ContentView.swift (new jsAMF3Encoder module + _TSORPC namespace).

 Phase 4 — Specialist state extraction (~half day)

 Extend jsAMF3Scanner to also collect dSpecialistVO from the same scan walk that already finds collectibles. Each specialist needs:

 - uniqueID (composite uniqueID1:uniqueID2)
 - specialistType (Explorer / Geologist / General / etc. — confirm enum from a captured payload)
 - name, level, skillTree (or whatever's exposed)
 - currentTask (null if idle) + taskEndTime if busy

 New JS→Swift message SPECIALISTS with {items: [...]}.

 Swift side: new SpecialistsStore.swift (@Observable); add case specialists(SpecialistsPayload) to InboundMessage; decode in
 BridgeProtocol.swift; thread the store through WebView like CollectiblesStore.

 Files touched: ContentView.swift, BridgeProtocol.swift, new SpecialistsStore.swift, ContentView.swift (WebView/Coordinator to accept the new
 store).

 Phase 5 — Dispatch RPC (~half day)

 JS function dispatchSpecialist({specUid, taskCode, targetGrid, durationOption}):
 - Builds dStartSpecialistTaskVO with the field set learned in Phase 1.
 - Calls _TSORPC.sendServerAction(95, 12, targetSomething, 0, vo).

 Swift outbound: OutboundMessage.dispatchSpecialist(uid:, taskCode:, targetGrid:, duration:) →
 window.TSOBridge.receive({type:'DISPATCH_SPECIALIST', payload:{…}}).

 Verification: Dispatch one geologist from a fake button in Swift; specialist should appear "busy" in-game within ~1s.

 Files touched: ContentView.swift, BridgeProtocol.swift.

 Phase 6 — Side panel UI (~half day)

 Wrap the WebView in HSplitView with a 320pt right-hand panel:
 - Filter chips: Explorer / Geologist / General.
 - List(specialists) showing name + status + (if busy) countdown.
 - For each idle row: task Picker, "Dispatch" button.
 - For "Find deposit" task: secondary picker for deposit type (Coal/Iron/Gold/Titanium…).

 Live-updates from SpecialistsStore.

 Files touched: new SpecialistsPanel.swift, ContentView.swift (replace bare WebView with HSplitView).

 ---
 Critical files

 - TSOClient/TSOClient/ContentView.swift — all 4 phases of JS work + the HSplitView wrap.
 - TSOClient/TSOClient/BridgeProtocol.swift — new inbound + outbound cases.
 - TSOClient/TSOClient/CollectiblesStore.swift — unchanged; precedent for @Observable store layout.
 - New TSOClient/TSOClient/SpecialistsStore.swift — mirrors CollectiblesStore.
 - New TSOClient/TSOClient/SpecialistsPanel.swift — SwiftUI side panel.
 - CLAUDE.md — targeted edits to six sections.
 - log.md — append a "Specialist Dispatch" section after the milestone lands (mirrors existing Collectibles log style).

 Reused functions / patterns

 - AMFParser (ContentView.swift:775) — parser is the canonical reference for the encoder's byte-level conventions; mirror its method shape.
 - Scanner's scanTree (ContentView.swift:1114) and ctx.classes/ctx.exemplars indexing — Phase 4 piggybacks on the existing walk, doesn't add a
 new one.
 - _tsoSend (ContentView.swift:145) and TSOBridge.receive (ContentView.swift:154) — message bus, no changes needed.
 - OutboundMessage.send(to:) (ContentView.swift:120) — extend the enum, the send plumbing is fine as-is.
 - CollectiblesStore mutation pattern (Coordinator.userContentController at ContentView.swift:87, with DispatchQueue.main.async) —
 SpecialistsStore follows the same shape.

 Verification

 End-to-end test once Phase 6 lands:
 1. Build: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project TSOClient/TSOClient.xcodeproj -scheme TSOClient
 -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:" | head -40.
 2. Launch app. Log in. Wait for zone load. Collectibles still render pink (regression check on jsCollectiblePatcher).
 3. Side panel shows N specialists with correct names and types.
 4. Click "Dispatch" on one idle geologist for a Coal-finding task. Within ~1s the specialist row switches to "busy" with a countdown, and the
 in-game UI reflects the same state.
 5. Console log shows one [AMF3:out] SendServerAction(95,12,…) block and one [AMF3:fetch] block carrying the server's ack.
 6. Repeat for an idle explorer (Treasure task) and an idle general (move-to-zone task) to confirm task-code coverage.
 7. Regression: pickup a collectible in-game; COLLECTIBLES message arrives; pink texture refresh still works.

 Risk register

 - Envelope mismatch in Phase 2. If round-trip byte equality is hard to reach, fall back to "minimal envelope" — strip optional headers and see
 if the server still accepts. Verify by direct POST through the Web Inspector before integrating into the bridge.
 - CSRF / anti-replay token. Flex AMF requests sometimes carry a server-set token in a header (DSId). Phase 1 capture will reveal whether one
 exists; if so, sniff it from the first observed inbound response and replay in subsequent requests.
 - Realm shifts mid-session. The realm URL (r03-gs003.…) is observed at session start; if it changes (rare), the cached URL goes stale.
 Mitigation: on send failure, re-read from the most recent observed inbound request.
 - Specialist type enum mismatch. AS3 uses string-based class names; the AMF3 wire likely uses numeric type codes for specialistType. Capture the
  actual values before hardcoding the filter chips.

 ---
 Out of scope (deferred to follow-up milestones)

 - Multi-select + batch dispatch with 1 s throttle (à la AIR client's TimedQueue).
 - JSON template save/load (geo/explorer task presets).
 - Generals manager (template send to zone/star; needs same RPC primitive but bigger UI surface).
 - Buff Templates / Drunken Miner / Black Market — all unlocked by the Phase-3 primitive but each needs its own state model + UI.
 - Catalog file at project root (the prior request the user pivoted from). Hold until requested.
