# AMF boot audit — no definitions endpoint

Captured 2026-11-22 via `_tsoNetLog=true` + `_tsoDiag=true` on a cold reload.
Looking for a server-side "get buff/building definitions" endpoint analogous
to the `BuffDefinition.getDuration(applianceMode)` runtime used by the AIR
client (fedorovvl/tso_client). **Verdict: no such endpoint exists.**

To re-run: flip `window._tsoDiag=true` + `window._tsoNetLog=true` in Safari
Web Inspector, reload, grep `latest.log` for `[AMF3:` / `[BootClasses]` /
`[Exemplar]` entries.

## Cold-boot outbound opcodes (distinct `callType` values)

| Opcode | Call VO                 | Role                                          |
|--------|-------------------------|-----------------------------------------------|
| 1002   | `dZoneLoginVO`          | Zone-login → returns the player's entire zone state (~6.35 MB) |
| 1004   | `dUpdateVO`             | Periodic client-time / zone-checksum sync     |
| 1005   | —                       | Observed at boot; role TBD                    |
| 1014   | —                       | PlayerList (friends) — already catalogued     |
| 1062   | —                       | Public trades snapshot — already catalogued   |
| 1063   | —                       | Observed at boot; role TBD                    |
| 4014   | —                       | Observed at boot; role TBD (83 KB response)   |
| 15000  | —                       | Observed at boot; role TBD                    |

None are "get definitions". The 1002 ack is the big one at 6.35 MB but it's
**player state**, not a catalog.

## Candidate VO classes audited (all rejected)

Every class whose name hinted at "definition" was pulled from the boot
response and its exemplar inspected. None carry static buff durations or
static building production rates.

| Class                               | Count | What it actually is                                         | Duration field? |
|-------------------------------------|------:|-------------------------------------------------------------|-----------------|
| `EffectVO`                          |  238  | Generic "something happens": rewards, cancellations, removes. Fields: `effect_string` (`reward`/`removebuilding`/`cancelzonebuff`), `name_string`, `type_string`, `amount`, `chance`, `skillID`, `conditions` | ❌ No duration |
| `EffectListVO`                      |    2  | Wrapper: `list: ArrayCollection<EffectVO>`                   | ❌              |
| `CooldownVO`                        |    3  | Runtime cooldown tracker (`id`, `duration`, `starttime`, dirty). Sample `duration=0` → already elapsed, so it's state, not a definition | ⚠️ Field exists but runtime |
| `ConditionVO`                       |    4  | Gate: `uniqueID`, `amount`, `index`, `completed`, `trigger` | ❌              |
| `ConditionCollectionVO`             |    1  | List of ConditionVO                                           | ❌              |
| `dResourceCreationVO`               |  302  | **Runtime** production instance per path: `pathPos`, `playerId`, `settlerKIState`, `productionState` — NOT a production-rate catalog | ❌              |
| `ContentGenerator.ContentGeneratorContentVO` | 8 | Mail/letter content definition: `name`, `partName`, `partAmount`, `playerLevel`, `icon`, `loottableItems` (array of `EffectVO`) | n/a             |
| `dBuffVO`                           |  297  | **Inventory** buff: `uniqueId1/2`, `buffName_string`, `resourceName_string`, `amount`, `insertedAt` | ❌              |
| `dBuffApplianceVO` / `dPersistedBuffApplianceVO` | 256 | **Active** buff on a building/zone: `uniqueId`, `buffID`, `startTime`, `applianceMode`, `nextTickTime`, `resourceName_string` | ❌ (see below) |
| `dResourceVO`                       |  163  | Player resource stockpile: `name_string`, `amount`, `producedAmount` | ❌              |
| `TriggerVO` / `dQuestTriggerVO`     |  183  | Quest state tracking                                          | ❌              |
| `dRequirementVO`                    |  336  | Building-unlock gate: `type:0`, `value:"42"`, `amount`, `fulfilled`  | n/a — useful side find |
| `dQuestDefinitionVO` & friends      |  386  | Quest definitions (not buff/building)                         | ❌              |

## Side finds worth keeping

1. **`dBuffApplianceVO.applianceMode`** is wire-confirmed. Almost certainly
   an enum of duration tiers (self vs friend vs PFB-boosted). This is the
   lever for keying the duration learner.
2. **`requirements.buildingRequirements_vector`** in the 1002 ack is a
   dictionary of **every building's level-to-unlock**. Sample entries:
   `Butcher=22`, `Carpenter=43`, `ArchebuseMaker=56`, `ExoticWoodCutter=53`,
   `Wheelmaker=42`, `SimpleResidence=15`, `Barracks=15`. Useful if we ever
   want "unlocks at level N" badges in the buff panel or a building list.
3. **`ContentGeneratorContentVO` with embedded `EffectVO`s where `effect_string="reward"`**
   is the loot-table catalog for mail/letter rewards. Useful for future
   event-automation features.
4. **Class counts** summarised (ratio of state cardinality in the boot
   payload): `dMapValueItemVO` × 16,044, `dRequirementsVO` × 4,900,
   `dUniqueID` × 2,503, `dBackgroundTileVO` × 2,346 — these dominate the
   6.35 MB payload. Any scanner optimisation targeting them has the biggest
   impact.

## Why the hunt was worth running

Rules out a whole class of "surely there's a server-side definitions table"
work. Any future contributor can read this doc and skip straight to the
remaining options:

- **Observation-based learning** (current `BuffDurationLearner` approach).
- **Keying the learner on `applianceMode`** (collapses the state space).
- **Statically seeded catalog** from community sources (see `buff-catalog.md`).
- **Decompiling the Unity `.data` bundle** (declared out of scope).
