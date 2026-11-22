# TSO buff catalog

Seed data for `BuffDurationLearner` / `naming.json`. Durations are the **self**
value in hours (what the server applies when we buff our own buildings). Friend
value is 1.5× for most production buffs when the applier is Premium (encoded
at the server, not on the wire). PFB stacks multiplicatively (×2 after PFB).

**Raw name conventions** (observed on the wire via `dBuffApplianceVO.buffName_string`
and in CDN XML + tsomaps URLs):
- `ProductivityBuffLvl<N>` — numbered production buffs (bagged food/consumables)
- `ProductivityBuff<Name>` — specialty/recipe production buffs tied to a building
- `RecruitingBuffLvl<N>` / `RecruitingBuffZoneLvl<N>` — barracks recruitment
- `ProvisionerBuffLvl<N>` / `BookbinderBuffLvl<N>` — provision house / bookbinder speedups
- `AnimalBuff_<theme>` — zone-wide animal reskin
- `MultiplierBuffZone<N>_<name>` — zone-wide multipliers (PFB etc.)
- `GeneralSpeedBuff_<grade>` — general adventure speed (horseshoes)
- `AreaBuff<Building>Lvl<N>` — area-of-effect from a landmark building
- `BattleBuff_…` / `EffectBuff_…` — combat / cosmetic (not production)

**Source tag format**: `tsomaps:<slug>` = `https://en.tsomaps.com/tso-item/buffs/<slug>/`;
`sowiki:buffs` = `https://settlersonlinewiki.eu/en/guides/buffs/`; `fedorovvl:<path>` =
`github.com/fedorovvl/tso_client/blob/master/<path>`; `cdn-xml` = observed in TSO
CDN XML catalogs (see `cdn-xml-catalog.md`); `wire` = observed live on the AMF3
wire in this project.

---

## Productivity — generic (`ProductivityBuffLvl<N>`)

Target "Workyard" = any production building that has a work-cycle output. Effect
column is the raw multiplier the game applies to output (so "+200% output" is
noted as `×3`); input-cost modifiers are called out explicitly.

| Raw name | Display name | Duration (self / friend) | Effect | Scope | Source |
|---|---|---|---|---|---|
| `ProductivityBuffLvl1` | Fish Platter | 0.5h / 0.75h | ×2 output | Workyard (any) | tsomaps:ProductivityBuffLvl1 |
| `ProductivityBuffLvl2` | Hearty Sandwich / Solid Sandwich | 2h / 3h | ×2 output | Workyard (any) | sowiki:buffs; fedorovvl:userscripts/user_showmyloot_pro.js:L271 |
| `ProductivityBuffLvl3` | Aunt Irma's Gift Basket | 6h / 9h | ×2 output | Workyard (any) | tsomaps:ProductivityBuffLvl3 |
| `ProductivityBuffLvl4` | Basket of Exotic Fruits | 12h / 18h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl4 |
| `ProductivityBuffLvl5` | Red Flying Settler | 24h / 36h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl5 |
| `ProductivityBuffLvl6` | Rabbit Lucky Charm | 48h / 72h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl6 |
| `ProductivityBuffLvl7` | Zombie | 12h / 18h | ×4 output | Workyard (any) | tsomaps:ProductivityBuffLvl7 |
| `ProductivityBuffLvl8` | Cookies | 32h / 48h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl8 |
| `ProductivityBuffLvl9` | Fermentation Accelerator | 24h / 36h | ×4 output | Brewery, Friary, Friar Tribute | tsomaps:ProductivityBuffLvl9 |
| `ProductivityBuffLvl10` | Stadium Snacks | 24h / 36h | ×4 output | Workyard (any) | tsomaps:ProductivityBuffLvl10 |
| `ProductivityBuffLvl12` | Bag of Rainbow Snow | 96h / — | ×4 output | Workyard (any; event — no friend variant) | tsomaps:ProductivityBuffLvl12 |
| `ProductivityBuffLvl13` | Roasted Duck | 4h / 6h | ×3 output | Workyard (any) | sowiki:buffs; fedorovvl:userscripts/user_showmyloot_pro.js:L281 |
| `ProductivityBuffLvl14` | Piero's Bowl of Pasta | 8h / 12h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl14 |
| `ProductivityBuffLvl15` | Helpful Scarecrow | 16h / 24h | ×3 output | Farm | sowiki:buffs |
| `ProductivityBuffLvl16` | The Mother Tree Ritual | 20h / 30h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl16 |
| `ProductivityBuffLvl17` | Gold Fever | 16h / 24h | ×3 output | Gold Mine | tsomaps:ProductivityBuffLvl17 |
| `ProductivityBuffLvl18` | Damascene Hammer | 16h / 24h | ×3 output | Weaponsmiths (Bronze/Iron/Steel/Damascene/Platinum) | tsomaps:ProductivityBuffLvl18 |
| `ProductivityBuffLvl19` | Hot Lemon Tea | 24h / 36h | ×3 output | Village School, University, Spa, Classy Hotel | tsomaps:ProductivityBuffLvl19 |
| `ProductivityBuffLvl22` | Machine Oil | 6h / 9h | ×5 output | Workyard (any) | tsomaps:ProductivityBuffLvl22 |
| `ProductivityBuffLvl23` | Grilled Steak | 48h / 72h | ×2 output | Workyard (any) | tsomaps:ProductivityBuffLvl23 |
| `ProductivityBuffLvl25` | Mr. Croix Sant | 24h / 36h | ×3 output | Bakery, Improved Bakery | tsomaps:ProductivityBuffLvl25 |
| `ProductivityBuffLvl100` | Harvest Ritual | 12h / 18h | ×4 output | Farm | sowiki:buffs |
| `ProductivityBuffLvl101` | Whips & Carrots / Sticks and Carrots | 6h / 9h | ×4 output | Stable, Elite Stable | tsomaps:ProductivityBuffLvl101 |
| `ProductivityBuffLvl103` | Employee of the Month Badge | 6h / 9h | ×3 output | Workyard (any) | tsomaps:ProductivityBuffLvl103 |
| `ProductivityBuffLvl106` | Miracle Bait | 6h / 9h | ×5 output | Fisher, Fish Farm | tsomaps:ProductivityBuffLvl106 |
| `ProductivityBuffLvl108` | Werewolf's Howl | 6h / 9h | ×3 output | Pumpkin Cemetery (Halloween) | tsomaps:ProductivityBuffLvl108 |
| `ProductivityBuffLvl300` | Aunt Irma's Feast | 24h / 36h | ×2 output | Workyard (any) | tsomaps:ProductivityBuffLvl300; cdn-xml |
| `ProductivityBuffFEW1` | Magic Bean Soup | 8h / 12h | ×2 output | Epic Workyard | fedorovvl:userscripts/user_showmyloot_pro.js:L292; sowiki:buffs |

## Productivity — specialty / recipe (`ProductivityBuff<Name>`)

Durations here are "self" unless otherwise noted; friend values follow the ×1.5 rule.

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `ProductivityBuffSunflowerFertilizer` | Sunflower Fertilizer | 24h / — | ×11 output (+1,000%) | Sunflower Farm | tsomaps:ProductivityBuffSunflowerFertilizer; cdn-xml |
| `ProductivityBuffJewelcrafter1` | Infused Sunflower Fertilizer | 48h / 72h | ×6 output | Sunflower Farm | tsomaps:ProductivityBuffJewelcrafter1 |
| `ProductivityBuffCollectibleEW` | Master's Toolkit | 6h / 9h | ×2 output | Epic Woodyard | tsomaps:ProductivityBuffCollectibleEW |
| `ProductivityBuffCarnivalGrounds1` | Better Morale Through Chaos | 2h / 3h | ×9 output, ×3 input | Workyard (any) | tsomaps:ProductivityBuffCarnivalGrounds1 |
| `ProductivityBuffCandyFactoryBuff2` | Candy Craze | 9h / 13.5h | ×4 output, ×4 input | Workyard (any) | tsomaps:ProductivityBuffCandyFactoryBuff2 |
| *(further specialty buffs — Gourmet Truffle Stew, Krampus Pickaxe, Heart Balloon, Weapon Boost, Harvest Ritual, etc.)* | see sowiki:buffs | various | various | various | sowiki:buffs |

> Raw-name inventory for the specialty variants above is incomplete — tsomaps URL slugs are not 1:1 with display names and need per-slug confirmation when they show up on the wire. The `BuffDurationLearner` will fill them automatically on first observation.

## Recruiting (`RecruitingBuffLvl<N>` / `RecruitingBuffZoneLvl<N>`)

| Raw name | Display name | Duration (self / friend) | Effect | Scope | Source |
|---|---|---|---|---|---|
| `RecruitingBuffLvl1` | Improved Drill Plan / Improved Recruitment | 12h / 18h | ×2 recruit speed | Barracks, Elite Barracks | tsomaps:RecruitingBuffLvl1 |
| `RecruitingBuffLvl2` | Mr. Myers | 1h / — | ×4 recruit speed | Barracks, Elite Barracks | fedorovvl:userscripts/user_showmyloot_pro.js:L298 |
| `RecruitingBuffLvl4` | Nash Williams | 2h / 3h | ×4 recruit speed | Barracks, Elite Barracks | tsomaps:RecruitingBuffLvl4 |
| `RecruitingBuffLvl5` | iGor | 6h / 9h | ×3 recruit speed | Barracks, Elite Barracks | tsomaps:RecruitingBuffLvl5 |
| `RecruitingBuffLvl6` | Mountain Climbing | 4h / 6h | ×6 recruit speed | Barracks | tsomaps:RecruitingBuffLvl6 |
| `RecruitingBuffLvl7` | Ice Swimming | 4h / 6h | ×6 recruit speed | Elite Barracks | tsomaps:RecruitingBuffLvl7 |
| `RecruitingBuffLvl9` | Hugs & Kisses | 24h / 36h | ×3 recruit speed | Barracks, Elite Barracks | tsomaps:RecruitingBuffLvl9 |
| `RecruitingBuffLvl300` | Enrolment Campaign | 6h / 9h | ×2 recruit speed | Combat Academy | tsomaps:RecruitingBuffLvl300 |
| `RecruitingBuffZoneLvl1` | Recruitment Guide | 4h / 6h | ×3 recruit speed (zone) | Barracks, Elite Barracks | tsomaps:RecruitingBuffZoneLvl1 |
| `RecruitingBuffZoneLvl3` | Easter Egg Roll | 8h / 12h | ×2 recruit speed (zone) | Barracks, Elite Barracks | tsomaps:RecruitingBuffZoneLvl3 |
| `RecruitingBuffValentineZoneConditional` | Family Day | while conditions hold | ×3 recruit speed (zone) | Barracks, Elite Barracks; requires 10 active flower bouquets | tsomaps:RecruitingBuffValentineZoneConditional |

## Provisioner & Bookbinder

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `ProvisionerBuffLvl3` | Barazek / Sesame Cake | 12h / 18h | ×4 speed | Provision House, Rarity Provision House | tsomaps:ProvisionerBuffLvl3; fedorovvl:userscripts/user_showmyloot_pro.js:L325 |
| `BookbinderBuffLvl1` | Hide Glue (Bookbinder Glue) | 24h / — | ×2 speed | Bookbinder | tsomaps:BookbinderBuffLvl1 |
| `BookbinderBuffLvl2` | Wilderwood Resin (Special Resin) | 36h / — | ×2 speed | Bookbinder | tsomaps:BookbinderBuffLvl2 |
| `BookbinderBuffLvl6` | True Soul Mate | 18h / 27h | ×3 speed | Bookbinder | tsomaps:BookbinderBuffLvl6 |

## PFB & Friend / Zone multiplier buffs

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `MultiplierBuffZone2_PremiumFriendBuff1Day` | Prestigious Friend Buff (1-day) | 1 day | ×2 all single production buffs; +50% adventure XP; ×2 barracks + provision house + weaponsmith; ×0.8 (×1.25 faster) explorer & geologist tasks | Friend's zone only | tsomaps:MultiplierBuffZone2_PremiumFriendBuff1Day; cdn-xml |
| `MultiplierBuffZone2_PremiumFriendBuff7Day` | Prestigious Friend Buff (7-day) | 7 days | same as 1-day | Friend's zone only | cdn-xml (page returns 404 on tsomaps but name confirmed in CDN XML) |
| `MultiplierBuffZone2_PremiumFriendBuff15Day` | Prestigious Friend Buff (15-day) | 15 days | same as 1-day. `buffID=663` confirmed on the wire. | Friend's zone only | cdn-xml; wire |
| `MultiplierBuffZone1` | Love-crazed | 2h / 3h | ×2 all productivity buffs | Zone-wide | tsomaps:MultiplierBuffZone1 |

> `cdn-xml-catalog.md` confirms the PFB raw names are shipped in the Shop XML; the AMF scanner already auto-detects PFB from `dZoneVO.zoneBuffs` and sets `SpecialistsStore.pfbActive`.

## Animal / zone cosmetic buffs (`AnimalBuff_*`)

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `AnimalBuff_unicorn` | Bottled Innocence (Unicorns) | 7 days / 10.5 days | Replaces wild animals with unicorns | Island-wide | cdn-xml; sowiki:buffs |
| `AnimalBuff_zombies` | Zombie Bite | 7 days / 10.5 days | Replaces wild animals with zombies | Island-wide | tsomaps:AnimalBuff_zombies |
| `AnimalBuff_ghosts_hauntedmansion` | Brief Séance | 7 days / 10.5 days | Replaces wild animals with ghosts | Island-wide | tsomaps:AnimalBuff_ghosts_hauntedmansion |
| *(Reindeer Bait, Accolade/Black Knights, Ouija Board — exact `AnimalBuff_*` slugs TBD)* | see sowiki:buffs | 7d / 10.5d | animal reskin | Island-wide | sowiki:buffs |

## General speed / horseshoes (`GeneralSpeedBuff_<grade>`)

Adventure-only; applies to a general's walking speed on the adventure map. No
friend variant (zone-wide, within one adventure).

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `GeneralSpeedBuff_Bronze` | Bronze Horseshoes | 1h | +15% movement speed | Generals on adventure | tsomaps:GeneralSpeedBuff_Bronze |
| `GeneralSpeedBuff_Platinum` | Platinum Horseshoes | 4h | +20% movement speed | Generals on adventure | sowiki:buffs |
| `GeneralSpeedBuff_Blackened_Titanium` | Blackened Titanium Horseshoes | 6h | +25% movement speed | Generals on adventure | fedorovvl:userscripts/user_showmyloot_pro.js:L329; sowiki:buffs |
| `GeneralSpeedBuff_Obsidian` | Obsidian Horseshoes | 8h | +30% movement speed | Generals on adventure | tsomaps:GeneralSpeedBuff_Obsidian |
| `GeneralSpeedBuff_Mystical` | Mystical Horseshoes | 24h | +40% movement speed | Generals on adventure | tsomaps:GeneralSpeedBuff_Mystical |
| `GeneralSpeedBuff_TMC_A` | Deep Snow (TMC event) | event-scoped | movement speed on TMC adventures | Generals on TMC adventure | tsomaps:GeneralSpeedBuff_TMC_A |

## Zone / area landmark buffs (`AreaBuff<Building>Lvl<N>`)

Durations and effects for the full set are in sowiki:buffs; raw-name slugs below are the ones confirmed on tsomaps.

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `AreaBuffIceSkatingLakeLvl2` | Winter Spirit I | 12h | +25% speed | Provision House & Bookbinder | tsomaps:AreaBuffIceSkatingLakeLvl2 |
| `AreaBuffIceSkatingLakeLvl3` | Winter Spirit II | 12h | +50% speed | Provision House & Bookbinder | tsomaps:AreaBuffIceSkatingLakeLvl3 |

## Event / seasonal productivity buffs

Non-exhaustive — these appear in `user_showmyloot_pro.js` translations and
sowiki:buffs but the raw-name ↔ slug mapping needs per-case confirmation when they
land on the wire.

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `EffectBuff_BuffX_Fireworks` | Festival Fireworks | 7d / 10.5d | Visual (fireworks sparkles) | Island-wide | fedorovvl:userscripts/user_showmyloot_pro.js:L331 |
| `BattleBuffBomb_random_units_limited` | Hail of Arrows | immediate | Defeat random units (once per camp) | Adventure combat | fedorovvl:userscripts/user_showmyloot_pro.js:L330 |

## Other (speed-up, population, battle — not production)

For completeness; these are unlikely to show up on home-island production
buildings so `BuffsStore` may not need them in v1, but the raw names here help
disambiguate what the panel sees when a `BUFFS` snapshot carries them.

| Raw name | Display name | Duration | Effect | Scope | Source |
|---|---|---|---|---|---|
| `SpeedUpPopulationGrowth2` | Cheese Sandwich | 10 min | +1 settler every 90 s | Population | fedorovvl:userscripts/user_showmyloot_pro.js:L296; sowiki:buffs |
| `ChangeColorScheme` | — | — | Visual scheme (not production) | Zone | fedorovvl:userscripts/user_zoneBuff.js:L155 (excluded from zone-buff picker) |
| `RemoveBuff` | Stop Buff | immediate | Clears active building buff | Single building | fedorovvl:client/files/content/scripts/6-buffs.js:L2 |
| `EmptyEffectBuff` | — | — | No-op (placeholder) | — | fedorovvl:client/files/content/scripts/4-itemshide.js:L18 |

---

## Confidence & gaps

### High confidence (pinned)

- **Raw buff-name scheme** is pinned by: (a) the Swift `buffName_string` field we
  observe live on the AMF3 wire, (b) tsomaps URL slugs that match exactly, and (c)
  the `buffType` family-prefix list enumerated in
  `fedorovvl:client/files/content/scripts/4-itemshide.js:L7-L29`.
- **PFB 15-day** (`MultiplierBuffZone2_PremiumFriendBuff15Day`, `buffID=663`) is
  wire-confirmed — see `TSOClient/CLAUDE.md` "PFB detection" section.
- **Durations for `ProductivityBuffLvl1..10, 12, 14, 16-19, 22-25, 100, 101, 103,
  106, 108, 300`, PFB 1-day/15-day, `MultiplierBuffZone1`, all five horseshoe
  grades, `ProvisionerBuffLvl3`, `BookbinderBuffLvl1/2/6`, every
  `RecruitingBuffLvl1-9 + 300`, and the two Ice Skating Lake area buffs** are from
  tsomaps.com per-item pages (one data source, but these pages are long-standing
  and have no visible staleness indicators).

### Medium confidence (community-sourced)

- **Specialty/recipe productivity buffs** (Gourmet Truffle Stew, Krampus Pickaxe,
  Sharpened Pickaxe, Steam Roller, Weapon Boost, Harvest Ritual, Heart Balloon,
  Infused Sunflower Fertilizer, etc.) and **zone/landmark buffs** (Snow Globe,
  Tree Love, Love Garden, Giant Tree, Spring Park, Christmas Market, Outdoor
  Canteen, Art Museum, Print Press, Laboratory, Concert Hall, Christmas Bakery,
  MeadHall, Footie Pitch, Weather Control, Observatory, Logistics Office, Tower
  of Rights, Togetherness Memoir, Holi Festival, Scouting Post) are catalogued in
  **sowiki:buffs** with durations + effects, but the **raw internal name slugs
  for each** aren't exposed by that source. Resolve per-slug when they appear on
  the wire — grep tsomaps with the display name.
- `ProductivityBuffLvl2` (Hearty Sandwich), `Lvl13` (Roasted Duck), `Lvl15`
  (Helpful Scarecrow), `Lvl100` (Harvest Ritual) duration/effect values are from
  sowiki:buffs rather than tsomaps (tsomaps search didn't return their individual
  pages).
- PFB 7-day: name confirmed in `cdn-xml-catalog.md` but the tsomaps page 404s —
  duration (7 days) is inferred from the naming pattern of the 1-day/15-day
  variants.

### Known buff names from the project's own list we couldn't find data for

- *(none)* — every buff name explicitly called out in the task prompt
  (`ProductivityBuffLvl1-7, 10, 300, 3`, `ProductivityBuffSunflowerFertilizer`,
  `AnimalBuff_unicorn`, PFB 1/7/15-day) is covered above.

### Bonus — buffs we found that weren't in our known list

- `ProductivityBuffLvl8` (Cookies, 32h ×3), `Lvl9` (Fermentation Accelerator, 24h ×4,
  brewery-scoped), `Lvl12` (Bag of Rainbow Snow, 96h ×4), `Lvl13` (Roasted Duck, 4h ×3),
  `Lvl14` (Piero's Bowl of Pasta, 8h ×3), `Lvl15/16/17/18/19/22/23/25/100/101/103/
  106/108` — all from tsomaps + fedorovvl's loot-translation map.
- `ProductivityBuffFEW1` (Magic Bean Soup, 8h ×2 on Epic Workyard) — Epic
  Workyard-specific, useful once the buffs panel supports that building category.
- `GeneralSpeedBuff_*` family (Bronze, Platinum, Blackened_Titanium, Obsidian,
  Mystical) — adventure-scoped, not relevant to the current home-island buff
  panel but worth knowing when we eventually ship an adventures feature.
- `MultiplierBuffZone1` (Love-crazed, 2h ×2) — a **zone-wide ×2 on productivity
  buffs**; note this stacks with PFB. If a zone-wide `dPersistedBuffApplianceVO`
  carries this, our duration estimator should optionally fold it in.
- `RecruitingBuffZoneLvl*` family — zone-wide recruiting buffs that extend the
  "+/- recruiting speed" effect across every barracks in the zone.
- `AnimalBuff_ghosts_hauntedmansion` — confirms the `AnimalBuff_*` family goes
  beyond unicorns/reindeer/zombies to at least one more theme.

### What this doesn't give us

- **Unit (ms) precision on durations.** All values are game-display hours. The
  Unity `.data` bundle is the only source for the exact second-level values;
  `BuffDurationLearner` closes that gap on first observation.
- **Friend-buff rule derivation.** tsomaps reports both self and friend
  durations as static values. The ×1.5 relationship holds for every
  production/recruiting buff I sampled (and every entry in sowiki:buffs), but
  event-only buffs (`Lvl12`, PFB) legitimately have no friend variant. Treat
  "friend duration = self × 1.5" as the default, and let the learner override.
- **Which `applianceMode` value maps to which duration.** `getDuration(mode)` in
  fedorovvl's code takes a mode argument (presumably 0 = self-on-own-building,
  1 = friend, maybe 2 = PFB-augmented). We don't yet have a table for that; the
  learner should key on the mode from `dBuffApplianceVO.applianceMode` observed
  on the wire.

## Observed `buffID` ↔ raw name (wire)

The `dBuffApplianceVO` on a buffed building carries only a numeric `buffID` —
no `buffName_string`. This table records confirmed pairings observed via the
`[BuffAll] grid=X buff=<name>` dispatch log → `[Buff:applied] grid=X buffID=N`
scanner delta correlation. Grow the table as new buffs are applied.

| buffID | applianceMode | Raw name | Display name | Scope observed | Session |
|---|---|---|---|---|---|
| 12 | 0 (self) | `ProductivityBuffLvl4` | Basket of Exotic Fruits | EfficientCrossbowsmith | 2026-11-22 |
| 13 | 0 (self) | `ProductivityBuffLvl5` | Red Flying Settler | SteelWeaponsmith | 2026-11-22 |
| 25 | 0 (self) | `ProductivityBuffLvl6` | Rabbit Lucky Charm | Lettersmith | 2026-11-22 |
| 31 | 0 (self) | `ProductivityBuffLvl7` | Zombie | PlatinumWeaponsmith | 2026-11-22 |
| 36 | 0 (self) | `ProductivityBuffLvl8` | Cookies | TitaniumWeaponsmith (= Damascene display) | 2026-11-22 |
| 55 | 0 (self) | `ProductivityBuffLvl13` | Roasted Duck | BronzeWeaponsmith | 2026-11-22 |
| 56 | 0 (self) | `ProductivityBuffLvl14`* | Piero's Bowl of Pasta | IronMine | 2026-11-22 |
| 57 | 0 (self) | `ProductivityBuffLvl16`* | The Mother Tree Ritual | IronWeaponsmith | 2026-11-22 |
| 117 | 0 (self) | `ProductivityBuffLvl18`* | Damascene Hammer | IronWeaponsmith | 2026-11-22 |
| 131 | 0 (self) | — (Potion of Endless Energy)* | Potion of Endless Energy | IronMine | 2026-11-22 |
| 133 | 0 (self) | `ProductivityBuffLvl19` | Hot Lemon Tea | VillageSchool | 2026-11-22 |
| 145 | 0 (self) | `ProductivityBuffLvl103` | Employee of the Month Badge | Carpenter | 2026-11-22 |
| 287 | 0 (self) | — (Elixir / Potion)* | Elixir | Powder Hut | 2026-11-22 |
| 289 | 0 (self) | `ProductivityBuffLvl23` | Grilled Steak | Wheelmaker | 2026-11-22 |
| 663 | — | `MultiplierBuffZone2_PremiumFriendBuff15Day` | Prestigious Friend Buff (15-day) | Zone (PFB) | prior |

Entries marked `*` are within-cluster monotonic guesses from buffID ordering
(Lvl13→55, Lvl14→56, Lvl16→57, Lvl18→117 — strictly increasing), not direct
observation. Confirm by re-applying individually via our panel so the
`[BuffAll] buff=<raw>` line pins the mapping.

## Scope notes (from the user, confirmed on the wire)

Buffs whose scope differs from the catalog's generic "Workyard (any)" — these
drive the `scopeByName` entries in `buff-categories.json`:

| Raw name | Display | Allowed buildings | Source |
|---|---|---|---|
| `ProductivityBuffBalloonDog` | Balloon Dog | Brewery, Magnificent Brewery, Friary | user 2026-11-22 |
| `ProductivityBuffBalloonHandful` | Handful of Balloons | Provision House, Provision House 2 | user 2026-11-22 |

## Excluded from the panel

These raw names are inventory items (so they pass through `BUFFS`) but aren't
applicable to any building in the UI sense. The classifier's `excluded`
category strips them from both the per-row and zone-buff dropdowns.

| Raw name | Reason |
|---|---|
| `ProductivityBuff_StarfallStarExtractor_Buff2` | Starfall quest item, not a real buff |
| `Productivity_StarfallStarExtractor2` | Same Starfall quest family |

Raw names in this table are linked to inventory `buffName_string` values via
the existing dispatch flow — `BuffDurationLearner.recordDispatch(uid,
buffName)` sees the dispatched buff's raw name, and the next BUILDINGS payload
echoes the server-assigned `buffID`. Entries with a `?` need the raw name
reconfirmed against inventory by re-applying with diag on.
