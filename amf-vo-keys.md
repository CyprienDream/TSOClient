# AMF VO key reference — `dPlayerVO` & `dZoneVO`

Snapshot of the two top-level VOs that carry virtually all per-zone state on a
`GameServer/amf` zone-load response. Captured 2026-06-14 from a live home zone
(`Sandycove`, owner+visitor = player 1582250). Use this as a lookup table when
adding new features; if the game updates and a field name shifts, re-capture by
re-enabling the `[PFB:rootkey]` diagnostic in `amf3-scanner.js`.

Notation under "Type":
- `number(N)`, `string(S)`, `boolean(B)` — scalar with value summary
- `Vector[N]<ClassName>` — Flex `ArrayCollection` of N items of that class
- `ClassName{...}` — nested VO; only first few keys are listed
- `object{k1,k2,...}` — plain dictionary (e.g. `Map<int, VO>`)

⭐ marks fields we currently read; 🟡 marks fields we know are useful but
haven't wired up yet.

---

## `dPlayerVO` — per-player state

The player profile. There is exactly one of these for the local player, plus
one nested under `dZoneVO.playersOnMap` for each player whose army is on the
current zone.

### Identity & account

| Field | Type | Notes |
|---|---|---|
| `username_string` | string | Display name (e.g. `AirDream`). |
| `userID` | number | Stable account ID (matches `zoneID` for home zone). |
| `zoneID` | number | Home zone ID. |
| `uniqueID` | dUniqueID | `{uniqueID1, uniqueID2}` composite. |
| `avatarId` | number | Avatar choice. |
| `canCheat` | boolean | Test-account flag. |
| `landingZoneID` | number | 0 when home, otherwise the visiting zone. |
| `guildId` | number | 0 if unguilded. |
| `guildMaxSize` | number | Per-guild member cap. |
| `blackMarketUnlocked` | boolean | Black-market UI gate. |

### Progression

| Field | Type | Notes |
|---|---|---|
| ⭐ `playerLevel` | number | Used to gate Geologist tasks (see `GeologistTask.minLevel`). |
| `xp` | number | Total experience. |
| `cityLevel` | number | Capital-level (separate progression). |
| `pvpLevel` | number | PvP league level. |
| `pvpXp` | number | PvP experience. |
| `bonusValipXp` | number | Bonus XP carryover. |
| `claimedPvpLevel` | number | Last claimed PvP reward level. |
| `pvpModifier` | number | PvP scaling factor. |

### Specialist & build counts (cheap snapshot ints — no need to walk vectors)

| Field | Type | Notes |
|---|---|---|
| `admiralAmount` | number | |
| `generalsAmount` | number | |
| `explorersAmount` | number | |
| `geologistsAmount` | number | |
| `currentMaximumBuildingsCountAll` | number | Hard cap incl. event/temp slots. |
| `permanentBuildQueueSlotsCount` | number | |
| `colonySlotCountPermanent` | number | |
| `colonySlotCountTemp` | number | |

### Resources & inventory

| Field | Type | Notes |
|---|---|---|
| `resources` | Vector[0] | Empty in zone responses — resource counts live on `dResourcesVO` under `dZoneVO`. |
| ⭐ `availableBuffs_vector` | Vector<dBuffVO> | **Buff inventory** (217 entries in the capture). What the player owns/can apply. Not active state. Drives the `BuffsStore`. |
| `purchasedShopItems_vector` | Vector<dPurchasedShopItemVO> | Purchase history (121 entries). |
| `availableTempSlots_vector` | Vector<dTempBuildSlotVO> | Temporary build slots. |
| `discoveredSectors` | Vector<dSectorDiscoveryVO> | Map-fog progression (24 sectors). |
| `knownHelp_vector` | Vector | Tutorial bits seen (49 entries). |
| `hideHelp` | boolean | "Don't show help again" flag. |

### Premium

| Field | Type | Notes |
|---|---|---|
| 🟡 `premiumUntil` | number | Unix ms when premium expires (e.g. `1781549146605`). Could drive a "Premium active" badge. |
| `premiumExpiredNotified` | number | 0/1 — whether expiry toast was shown. |

### Skills

| Field | Type | Notes |
|---|---|---|
| `skills` | Vector<SkillVO> | Player-level skills (separate from specialist skills). |

---

## `dZoneVO` — current zone state

The single top-level VO carrying the entire current zone snapshot. Hundreds of
KB on a home zone. Detected by `mapWidth > 0 && mapHeight > 0`.

### Zone identity & ownership

| Field | Type | Notes |
|---|---|---|
| `zoneOwnerPlayerID` | number | The player who owns this zone. |
| `zoneVisitorPlayerID` | number | The viewer (= owner on own island). |
| `zoneMapName` | string | Asset path, e.g. `world/HomeZone_Release_Onyx.xm`. |
| `gameWorldName` | string | World/realm name (e.g. `Sandycove`). |
| `randomSeed` | number | Zone RNG seed. |

### Time & server clock

| Field | Type | Notes |
|---|---|---|
| ⭐ `serverTime` | number | Server-internal monotonic clock (ms). Used in conjunction with specialist `collectedTime`. |
| `serverTimeStamp` | number | Wall-clock Unix ms (e.g. `1781468394214`). Useful for converting `insertedAt` deltas to wall time. |
| `lastGameTickRefreshTime` | number | Last server tick. |
| `realmTimeOffset` | number | Realm-local TZ offset (hours). |
| `guildQuestTimeOffset` | number | Guild-quest TZ offset. |
| `gameTickRefreshCounter` | number | Monotonic tick counter. |
| `lastColonyYieldCalculationTime` | number | Last colony payout. |

### Active buffs ⭐

| Field | Type | Notes |
|---|---|---|
| ⭐ `zoneBuffs` | Vector<dPersistedBuffApplianceVO> | **Active player-wide buffs.** Where Prestigious Friend Buff lives when applied. 2 entries in the capture (PFB + one other). Each entry references its buff definition by numeric `buffID` only — the name string is **not** stored on the appliance (it must be resolved via a separate definition table or hardcoded ID list). |

#### `dPersistedBuffApplianceVO` shape (captured 2026-06-14)

```json
{
  "__class":         "dPersistedBuffApplianceVO",
  "dirtyIndicator":  { "__class": "DirtyIndicator", "value": 0 },
  "uniqueId":        { "uniqueID1": 1582250, "uniqueID2": 0 },
  "buffID":          663,
  "startTime":       45315868317,
  "applianceMode":   31,
  "resourceName_string": "",
  "sourceZoneId":    0,
  "nextTickTime":    0
}
```

- `buffID` — numeric reference to the buff definition. **No name string is
  carried on the appliance**, so detection requires either an ID→name map or
  a known-ID list. Confirmed: `buffID 663` = `MultiplierBuffZone2_PremiumFriendBuff15Day` on realm r03 (inventory copy of the 1Day token shares the family but has its own definition ID, not yet captured).
- `startTime` — server-clock value (ms), comparable to `dZoneVO.serverTime`.
  `(serverTime − startTime) / 1000` = real seconds elapsed since application.
- `applianceMode` — meaning unknown (PFB = 31 in capture).
- `uniqueId` — appliance instance ID, set to `{uniqueID1: <zoneOwnerPlayerID>, uniqueID2: 0}` for the captured PFB.
- `sourceZoneId` — 0 when applied to the local zone.
- No `endTime` field; expiry has to be derived from `startTime + variantDuration` (1Day = 86_400_000 ms, etc.).

Known PFB buff IDs (extend in `amf3-scanner.js` `PFB_BUFF_IDS` as variants are captured):

| `buffID` | Buff name | Variant |
|---|---|---|
| ? | `MultiplierBuffZone2_PremiumFriendBuff1Day` | 1-day (unconfirmed) |
| ? | `MultiplierBuffZone2_PremiumFriendBuff7Day` | 7-day (unconfirmed) |
| 663 | `MultiplierBuffZone2_PremiumFriendBuff15Day` | 15-day ✅ |

The other appliance seen alongside (`buffID 986`, `applianceMode 3`) is some unrelated zone-wide buff (likely Premium Time or Premium Compensation Buff) — not PFB.

### Map dimensions

| Field | Type | Notes |
|---|---|---|
| ⭐ `mapWidth` | number | 89 in capture. Used for `gridX = gi % mapWidth`. |
| ⭐ `mapHeight` | number | 196. |
| `backgoundMapWidth` | number | 46. (sic — `backgound`, not `background`.) |
| `backgoundMapHeight` | number | 51. |
| `streetMapMinUsableX` | number | 2. |
| `streetMapMaxUsableX` | number | 85. |
| `streetMapMinUsableY` | number | 2. |
| `streetMapMaxUsableY` | number | 192. |
| `maximumBuildingCount` | number | -1 = unlimited per cap. |
| `startGrid` | number | -1 = none. |

### World content

| Field | Type | Count | Notes |
|---|---|---|---|
| ⭐ `buildings` | Vector<dBuildingVO> | 541 | Every building incl. collectibles. |
| ⭐ `specialists_vector` | Vector<dSpecialistVO> | 57 | Drives `SpecialistsStore`. |
| `deposits` | Vector<dDepositVO> | 1163 | Resource deposits. |
| `landscapes` | Vector<dLandscapeVO> | 2106 | |
| `freeLandscapes` | Vector<dFreeLandscapeVO> | 1096 | |
| `overFogLandscapes` | Vector | 0 | |
| `streets` | Vector<dStreetVO> | 1366 | |
| `resourceCreations` | Vector<dResourceCreationVO> | 270 | Resource node configs. |
| `sectors` | Vector<dSectorVO> | 24 | Fog/territory sectors. |
| `backgroundTiles` | Vector<dBackgroundTileVO> | 2346 | |
| `landingFields` | Vector<dLandingFieldVO> | 11 | |
| `playersOnMap` | Vector<dPlayerVO> | 1 | Visiting players (only self on home). |
| `mapValues` | Vector<dMapValueItemVO> | 16044 | Per-tile metadata. |
| `depositGroups` | Vector | 0 | |
| `depositQualities` | Vector | 0 | |

### Specialist & production state

| Field | Type | Notes |
|---|---|---|
| `specialistActivity_vector` | Vector | Active specialist tasks (0 in capture). |
| `timedProductions_vector` | Vector<ArrayCollection> | Active production timers (20 in capture). |
| `gameTickCommands_vector` | Vector<dGameTickCommandVO> | Pending tick-based commands (5). |
| `hiredTroopsPool` | Vector | Hired-mercs pool. |
| `map_PlayerID_Army` | object<int,…> | Armies on map keyed by playerID. |
| `buildQueue` | dBuildQueueVO | `{maxCount, permanentSlotsCount, tempSlotsCount}`. |

### Resources (zone-wide)

| Field | Type | Notes |
|---|---|---|
| `resourcesVO` | dResourcesVO | `{workers, military, free}`. |

### Quests, achievements, tasks

| Field | Type | Notes |
|---|---|---|
| `questDefinitionContainer` | null | Loaded separately. |
| `clientQuestPool` | dQuestPoolVO | `{mQuestVO_vector}`. |
| `activeQuestOldQuestSystem` | null | Legacy quest VO. |
| `requirements` | dRequirementListsVO | Building/production/specialist gates. |
| `userAchievementData` | UserAchievementDataVO | `{userID, achievementTriggerValueUpdates, finishedAchievementTriggers}`. |
| `comparedUsersAchievementData` | Vector | Other players' achievements being compared. |
| `tasksData` | TaskDataVO | `{userID, taskResetTime, tasksToStart}`. |
| `compareTaskData` | Vector | Comparison data for tasks. |
| `dataTracking_vector` | Vector<dDataTrackingVO> | Telemetry (11). |
| `itemRegistryEntries` | Vector<dPersistedItemRegistryVO> | Persisted item registry (15). |

### Adventures & colonies

| Field | Type | Notes |
|---|---|---|
| `adventureName` | null | When on an adventure zone. |
| `adventureState` | number | Adventure progress code. |
| `colonyState` | number | Colony state code. |
| `colonies` | Vector | Player's colonies. |
| `combatPreviewPaths` | Vector | Battle-preview routes. |

### Calendar & events

| Field | Type | Notes |
|---|---|---|
| `adventCalendarDoors` | Vector | Advent calendar entries. |
| `adventAssetPrefix` | string | Asset prefix for advent. |
| `eventTimes` | Vector | Active event schedules. |
| `eventToActivate` | string | Pending event activation. |
| `cooldowns` | Vector<CooldownVO> | Active cooldown timers (3). |
| `pickupsDataVO` | PickupsDataVO | `{numberOfGeneratedPickups, generatedPickupsType}`. |
| `eventPickupsDataVO` | PickupsDataVO | Event-specific pickups. |
| `pickups` | Vector<dPersistedPickupItemVO> | Persisted pickups on map (1). |

### Guild / voting

| Field | Type | Notes |
|---|---|---|
| `playerGuildMarketVote` | dPlayerVoteVO | `{name, playerID, definitionID}`. |
| `contest` | null | Current contest. |
| `historyVotedShopItems` | object<int,...> | Past shop votes. |

### Content generators

| Field | Type | Notes |
|---|---|---|
| `contentGeneratorDefinitions` | Vector<ContentGeneratorCategoryVO> | 3 in capture. |
| `contentGeneratorCollectionParts` | Vector<CollectionPartVO> | 5. |
| `genericValues` | Vector<GenericValueVO> | 6. |

### Misc / settings

| Field | Type | Notes |
|---|---|---|
| `activateProduction` | boolean | |
| `filter` | number | UI filter state. |
| `settings` | dSettingsVO | `{eventLadderURL_string, expeditionMapLevelGroupVO, expeditionDifficultyVO}`. |
| `alternativeWater` | boolean | Water style swap. |
| `maxAnimalsOnMap` | number | 100. |
| `hasAltDefaultAnimals` | boolean | |
| `defaultAnimals` | object | Per-zone default animal set. |
| `useContinentalFog` | boolean | |
| `playerResources_string` | string | Empty in capture. |
| `minimumPlayerLevel` | number | -1 = unrestricted. |
| `playerOptions` | PlayerOptionsVO | `{options}`. |
| `conditionCollection` | ConditionCollectionVO | `{conditions}`. |

---

## Class counts seen on a zone load (selected)

From the same capture:

- `dBuffVO` = 305 (217 in `availableBuffs_vector` + others appearing nested in shop items, etc.)
- `dBuffApplianceVO` = 184 (per-building active buffs, accessed via `dBuildingVO.buffs[0]`).
- `dPersistedBuffApplianceVO` = 2 (the **active zone-wide** buffs — see `dZoneVO.zoneBuffs`).

This three-way split is the key insight for buff detection: inventory =
`dBuffVO` in `availableBuffs_vector`, per-building active = `dBuffApplianceVO`
in `dBuildingVO.buffs`, zone-wide active (PFB etc.) =
`dPersistedBuffApplianceVO` in `dZoneVO.zoneBuffs`.

---

## How to regenerate

In `TSOClient/Resources/JS/amf3-scanner.js`:
- The `dumpRootKeysOnce` function emits `[PFB:rootkey]` lines for every key on
  the first `dPlayerVO` and `dZoneVO` it sees (per app launch).
- The `[PFB:buffclasses]` line emits class counts for any `*Buff*` class.
- The `[PFB:appliance.sample]` line emits the full JSON of the first
  `dPersistedBuffApplianceVO` it encounters.

Watch the Xcode console (`[JS] [PFB:…]` prefix) on next zone load, copy the
output, paste it back into this file under a new dated section if anything has
shifted.
