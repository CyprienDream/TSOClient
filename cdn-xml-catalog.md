# TSO CDN asset catalog

Startup-fetched XML and binary assets on `www.thesettlersonline.com/frontend/`.
Captured 2026-11-22 via `window._tsoNetLog = true` in amf3-net.js + a page
reload (first ~30 requests of a cold-start session). Hashed filenames change
with game patches; the **content shape** (root element + what it defines) is
the stable reference.

To re-discover: enable `_tsoNetLog`, `window.location.reload()` in Safari Web
Inspector, grep `latest.log` for `[Net]` entries.

## Unity bundle

| Request | URL | Role |
|---|---|---|
| #1 | `Build/<hash>.wasm` | Unity WebAssembly binary. `application/wasm`, ~1.4 MB. Contains the game logic + opaque static data (buff durations, building production rates, etc.). **Not reachable from JS.** |
| #2 | `Build/<hash>.data` | Unity data bundle. Binary blob. Likely source of buff-duration-style static tables. Not parseable from JS without reverse-engineering. |

## XML catalogs (root level `frontend/GFX_HASHED/*.xml`)

25 distinct root-level XML files fetched during cold startup. Entries inside
them that reference buffs do so by **name only** (e.g. `<Item type="Buff" name="ProductivityBuffLvl7"/>`);
no XML carries a `name → duration` table — that mapping is in the Unity .data
bundle.

| Root element | Content | Buff-relevant? |
|---|---|---|
| `SpecialistGroups` | Tavern recruit costs per specialist group (Coin + HardCurrency, scaled by tavern upgrade level). | No. |
| `Root` (ResourceIcons) | Resource + buff name → icon filename + category mapping. Example: `<ResourceIcon name="ProductivityBuffLvl1" filename="sushi_plate.png"/>`. | Names only, no durations. |
| `Configuration` (shop/UI) | Shop banners, analytics tracking IDs, country/language chat channels. | No. |
| `GameUnit` | Military unit stats — ArmorType, HP, BaseDamage, costs. Covers PvP defenders and NPC factions (`BanditRecruitTier1`, etc.). | No. |
| `Root` (game settings — large) | Global game constants: `<BuildingDefaultParameter constructionDuration=…/>`, `<Lifetime type=… timeHours=…/>` (mail inbox lifetimes, NOT buff durations), chat cooldown, repair round duration. Buffs appear only inside `<LootTable>` reward lists. | No buff duration block. Confirmed: no top-level `<BuffDefinitions>`/`<Buffs>`/`<BuffCatalog>` element. |
| `Adventures` | Playable adventures/raids/expeditions. Each `<Adventure>` or `<BuffAdventure>` carries a `durationHours` attribute (**adventure real-time duration**, not buff duration). Includes `adventureBuffGroup` + `adventureResources` for buff-adventure variants. | Adventure durations only. |
| `root` (Epic Workyards #1) | Epic Workyard building configurations + production chain upgrades (wood/corn/ore workyards, festival hall balloon mechanics). | No. |
| `Sounds` | `<Loops>` background music + `<Effects>` sound effects. | No. |
| `root` (generic values) | Game counter/state defaults (id, name, default triples). | No. |
| `ShopConfig` | Shop items. Buffs referenced by name (e.g. `<Item type="Buff" name="ProductivityBuffLvl4"/>`), no duration data. | Names only. |
| `Group` (shop groups #1) | Shop item groups referencing ProductivityBuffLvl5, AnimalBuff_unicorn, etc. | Names only. |
| `root` (3e32…) | References `MultiplierBuffZone2_PremiumFriendBuff1Day` and similar PFB variants — but no duration attribute at this VO level. | Names only. |
| `Root` (help) | `<HelpDefinition>` entries for the in-game help UI. | No. |
| `triggers` | Localization trigger names (strings fired on `buffapplied`, `buildingupgraded`, etc.). | Event names only. |
| `ItemLimits` | Per-item max-owned caps. | No. |
| `root` (events #1) | Game events — trigger definitions mapped to UI open/close actions. | No. |
| `root` (events #2) | Event UI properties + button-driven quest/skill effects. | No. |
| `root` (collections) | Collection definitions, loot tables, spawn lists, resource definitions. `productionTime` present but refers to crafting, not buffs. | No buff durations. |
| `root` (tasks) | Task definitions with rewards (buffs appear in reward blocks only). | Names only. |
| `BlackMarketConfig` | Black market auction costs + increments. | No. |
| `Group` (shop groups #2) | Adventure-buff bundles for the shop. | No durations. |
| `Votes` | Guild/market vote pools + gem costs. | No. |
| `root` (Epic Workyards #2) | Second workyard catalog (specializations). | No. |
| `reactions` | Reaction system — applies/cancels buffs conditionally. References existing buff names only. | Names only. |
| `root` (achievements) | Achievement triggers, reward handlers, categories. | No. |

## Takeaways

1. **No XML carries buff durations.** The Unity `.data` bundle is the only
   client-side source, and it's binary-opaque. Durations must come from
   observation (see `BuffDurationLearner`) or user-curated values.
2. **Buff names present in catalogs**: `ProductivityBuffLvl1..7`, `ProductivityBuffLvl300`,
   `AnimalBuff_unicorn`, `MultiplierBuffZone2_PremiumFriendBuff1Day/7Day/15Day`,
   and adventure-buff variants. Good seed list for any future buff-metadata
   feature (e.g. a dropdown of all known buff names).
3. **Opening the in-game Buff shop/tooltip triggered zero new XML fetches** —
   confirms the UI reads from already-loaded Unity data, not a lazy-loaded
   JSON/XML asset.
4. **Mail `<Lifetime>` entries ≠ buff durations.** `<Lifetime type='BuffedBuilding' timeHours='168'/>`
   is how long the "your building was buffed" mail message stays in the inbox,
   not how long the buff lasts on the building.
5. **Adventures carry `durationHours`** directly in the Adventures XML —
   useful if we later ship an Adventures feature.
6. **GameServer AMF classes seen for buffs**: only `dBuffApplianceVO` (per-building
   active buff — `buffID`, `startTime` ms since server epoch, `applianceMode`,
   `nextTickTime`, `resourceName_string`, `sourceZoneId`) and `dPersistedBuffApplianceVO`
   (zone-wide, PFB — see `amf-vo-keys.md`). No definition VO.
