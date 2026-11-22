import Foundation

// Learns buff durations by watching our own dispatches expire. The game's
// buff-definitions catalog lives inside the Unity .data bundle (not in any
// XML the client fetches post-startup — see `amf-boot-audit.md` for the
// server-side exhaustion of other options), so we can't look durations up
// statically — we discover them from observed lifecycle instead.
//
// Keyed on (buffName, applianceMode). The server's duration depends on
// both: the same buff has different lifetimes depending on how it's
// applied (self vs friend vs PFB-boosted — `applianceMode` is the
// server's duration-tier enum). Averaging modes together would give
// wildly wrong estimates; the fallback chain below handles the case
// where we don't know the mode yet.
//
// Flow, per buff name + mode:
//   1. Coordinator calls `recordDispatch(uid, buffName)` immediately after
//      `dispatcher.dispatchBuff(...)`. We remember (uid → buffName, now).
//      Mode is nil at this point — we don't know it until the server
//      echoes back the appliance VO.
//   2. Every subsequent BUILDINGS payload calls `observe(buildings:now:)`.
//      For each tracked uid:
//        - if the building's activeBuff is still set and we haven't
//          captured a mode yet, latch `activeBuffApplianceMode` into the
//          tracked entry;
//        - if activeBuff dropped to nil, the buff expired → record
//          (buffName, capturedMode) → observed duration, forget the uid;
//        - if the building is gone (zone change), forget without learning.
//   3. `learnedDuration(for: buffName, applianceMode:)` tries the exact
//      (name, mode) key, then falls back to the max duration across any
//      mode for that name. Max keeps the "fire late, not early" bias from
//      the previous implementation.
//
// Persisted across launches via KeyValueStore under a versioned key. A
// legacy-key migration pulls buffName-only entries from the previous
// implementation into the new `name|*` any-mode slot so we don't lose
// learned data on upgrade.
@Observable
final class BuffDurationLearner {

    private struct TrackedDispatch {
        let buffName: String
        let dispatchedAt: Date
        var observedMode: Int?   // latched on first post-dispatch observation
    }

    // uid key = "uid1:uid2". Keyed consistently with BuildingItem.id so
    // callers can pass the same key they already have.
    private var tracked: [String: TrackedDispatch] = [:]

    // "<buffName>|<mode>" or "<buffName>|*" → observed duration (seconds).
    // `|*` is the any-mode fallback bucket, populated when the mode wasn't
    // captured before the buff expired (first-session, mid-dispatch
    // zone-change, etc.) and seeded by legacy-key migration. Max across
    // observations biases toward firing late rather than early.
    private(set) var learnedDurations: [String: TimeInterval] = [:]

    // Observations must exceed this before a sample is counted as a real
    // expiry. Blocks instant-retracked-as-expired noise if a BUILDINGS
    // payload arrives microseconds after a dispatch with stale data.
    var minObservedSeconds: TimeInterval = 60

    // Caps a learned duration to a reasonable game-time ceiling. Buff
    // durations in TSO top out around 24h for the common ones; we allow
    // some slack for weekend/special buffs but reject anything that'd be
    // obviously wrong (session paused for days, learner pollution, etc.).
    var maxObservedSeconds: TimeInterval = 72 * 3600

    private let defaults: KeyValueStore
    private let logger: Logger

    private enum Keys {
        // v1 schema: `[buffName: duration]`. Migrated on load into the new
        // `name|*` any-mode bucket; subsequent writes go to v2.
        static let learnedDurationsLegacy = "buffs.learnedDurations"
        // v2 schema: `[name|mode: duration]` with `|*` for the any-mode fallback.
        static let learnedDurations = "buffs.learnedDurationsByMode"
    }

    // Sentinel suffix used for the any-mode fallback bucket. Not a valid
    // Int so it can never collide with a real applianceMode key.
    private static let anyModeSuffix = "|*"

    init(defaults: KeyValueStore = UserDefaultsKeyValueStore(),
         logger: Logger = ConsoleLogger()) {
        self.defaults = defaults
        self.logger = logger
        // Prefer v2 if present.
        if let raw = defaults.dictionary(forKey: Keys.learnedDurations) {
            self.learnedDurations = raw.compactMapValues { $0 as? TimeInterval }
        } else if let legacy = defaults.dictionary(forKey: Keys.learnedDurationsLegacy) {
            // Migrate v1 buffName-only entries into the any-mode bucket so
            // the first post-upgrade lookup still benefits from historical
            // samples. v1 key stays untouched in defaults (one-way migration
            // — if the user downgrades, old data isn't lost).
            var migrated: [String: TimeInterval] = [:]
            for (name, val) in legacy {
                guard let secs = val as? TimeInterval else { continue }
                migrated[name + Self.anyModeSuffix] = secs
            }
            self.learnedDurations = migrated
            if !migrated.isEmpty {
                persist()
                logger.log("[BuffLearner] migrated \(migrated.count) v1 entries → any-mode bucket")
            }
        }
    }

    func recordDispatch(uidKey: String, buffName: String, at now: Date = Date()) {
        tracked[uidKey] = TrackedDispatch(
            buffName: buffName, dispatchedAt: now, observedMode: nil)
    }

    // Lookup with fallback chain:
    //   1. Exact (buffName, applianceMode) hit → that duration.
    //   2. Any-mode bucket for this buffName → that duration.
    //   3. Max across every mode-specific entry for this buffName.
    //   4. nil.
    // Max is used rather than mean because the learner's whole point is to
    // fire re-buff timers no earlier than true expiry; averaging would
    // sometimes land before.
    func learnedDuration(for buffName: String, applianceMode: Int?) -> TimeInterval? {
        if let mode = applianceMode,
           let hit = learnedDurations[Self.storageKey(buffName: buffName, mode: mode)] {
            return hit
        }
        if let anyMode = learnedDurations[buffName + Self.anyModeSuffix] {
            return anyMode
        }
        let prefix = buffName + "|"
        let modeSpecific = learnedDurations.lazy
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)
            .max()
        return modeSpecific
    }

    func cancelTracking(uidKey: String) {
        tracked.removeValue(forKey: uidKey)
    }

    // Called by the coordinator after every BUILDINGS payload applies.
    // Resolves tracked entries against the current state:
    //  - building still present + activeBuff != nil
    //      → latch `activeBuffApplianceMode` on the tracked entry if not
    //        yet captured; keep tracking
    //  - building present + activeBuff == nil → learn (buff expired),
    //    key on (buffName, latchedMode) or `|*` if we never caught it
    //  - building absent (zone change, destroyed) → forget silently
    func observe(buildings: [BuildingsStore.BuildingItem], now: Date = Date()) {
        guard !tracked.isEmpty else { return }
        var byUid: [String: BuildingsStore.BuildingItem] = [:]
        for b in buildings { byUid[b.id] = b }
        var forgotten: [String] = []
        for (uid, entry) in tracked {
            guard let building = byUid[uid] else {
                forgotten.append(uid)
                continue
            }
            if building.activeBuff != nil {
                if entry.observedMode == nil,
                   let mode = building.activeBuffApplianceMode {
                    var updated = entry
                    updated.observedMode = mode
                    tracked[uid] = updated
                }
                continue
            }
            let observed = now.timeIntervalSince(entry.dispatchedAt)
            forgotten.append(uid)
            guard observed >= minObservedSeconds, observed <= maxObservedSeconds else {
                logger.log("[BuffLearner] skip out-of-range sample buff=\(entry.buffName) s=\(Int(observed))")
                continue
            }
            let key = Self.storageKey(buffName: entry.buffName, mode: entry.observedMode)
            let prior = learnedDurations[key] ?? 0
            let next = max(prior, observed)
            if next != prior {
                learnedDurations[key] = next
                persist()
                let modeTag = entry.observedMode.map { "mode=\($0)" } ?? "mode=*"
                logger.log("[BuffLearner] learned buff=\(entry.buffName) \(modeTag) s=\(Int(observed)) (prior=\(Int(prior)))")
                logSnapshot()
            }
        }
        for uid in forgotten { tracked.removeValue(forKey: uid) }
    }

    // Prints the full learned-durations map in a readable form so tailing
    // `latest.log` doubles as a progress monitor. Fires after every new
    // learn in `observe()`; also callable on demand from anywhere that
    // needs the current picture.
    func logSnapshot() {
        if learnedDurations.isEmpty {
            logger.log("[BuffLearner] snapshot: (empty — no buffs learned yet)")
            return
        }
        // Group by buffName so each name's modes line up on one block.
        var byName: [String: [(mode: String, seconds: TimeInterval)]] = [:]
        for (key, secs) in learnedDurations {
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.count == 2 ? String(parts[0]) : key
            let mode = parts.count == 2 ? String(parts[1]) : "?"
            byName[name, default: []].append((mode, secs))
        }
        let names = byName.keys.sorted()
        logger.log("[BuffLearner] snapshot: \(learnedDurations.count) entries across \(names.count) buff name(s)")
        for name in names {
            let entries = byName[name]!.sorted { $0.mode < $1.mode }
            let tail = entries.map { "mode=\($0.mode):\(Int($0.seconds))s" }.joined(separator: ", ")
            logger.log("[BuffLearner]   \(name) — \(tail)")
        }
    }

    private static func storageKey(buffName: String, mode: Int?) -> String {
        if let m = mode { return "\(buffName)|\(m)" }
        return buffName + anyModeSuffix
    }

    private func persist() {
        defaults.set(learnedDurations, forKey: Keys.learnedDurations)
    }
}
