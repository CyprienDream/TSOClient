# Building skin reference

Snapshot of raw `skin` strings observed in a live `dBuildingVO` payload
(total = 533 buildings across a single zone). Used as the canonical
reference for what skinBase strings actually appear on the wire — consult
before adding entries to `building-categories.json` or
`ignored-buildings.json`. Counts are point-in-time and not load-bearing.

Casing is **load-bearing** (compare `Oilmill` vs `OilMill`, `benchGold`
vs `Bench`, `Farmfield` vs `FarmField`). The skin normalizer only
strips a trailing `_\d+` suffix — anything else (e.g. `_Mini`,
`_Mini_Gold`, `_Deco`, `_pop`, `_Purple`) survives as part of the
skinBase.

## Observed skin strings

```
AdmiralGarrison x4
AdvancedToolmaker x2
AdvancedToolmaker_mini x1
AdventureBookbinder x2
AirshipExcelsior x1
ArchebuseMaker x1
Bakery x5
BalloonMarket_mini x1
Barracks x1
Barracks3 x1
BlackTree_Purple
BoatHouse x2
Bonechurch_Pop x6
Bookbinder x1
Bookbinder_Mini_Gold x1
Bowmaker x2
Brewery x8
BronzeMine x6
BronzeMine_Mini x1
BronzeSmelter x4
BronzeWeaponsmith x1
Bungalow x1
Butcher x5
Butcher_Mini_Gold x1
CannonForge x1
Carpenter x1
ChristmasBakery x1
Coinage x2
Coinage_Mini x1
CokingPlant x10
Crossbowsmith x1
DarkRoofedWarehouse x1
Dark_Castle_01_Deco x1
DeerstalkerHut x2
DestroyableMountain_Mines x28
DestroyableMountain_Mountain_BIG_sw01 x5
DestroyableMountain_Mountain_BIG_sw02 x9
DestroyableMountain_Mountain_BIG_sw03 x16
EW_Wood_ExoticWoodToExoticPlank x3
Easter2017Deco_RabbitBush x2
EasterEvent2025_Residence x1
EasterEvent2026_Residence x1
Elari_Finesmith x1
ElderTreeLH x1
EliteBarracks x1
EliteStable x1
EliteTrainingGrounds x1
EpicCoalMine x1
EpicResidence x3
EpicWorkyardWood x1
EventMonster_WeeklyChallengeShip x1
ExoticWoodCutter x3
ExoticWoodForester x3
ExoticWoodSawmill x2
ExoticWoodTreeSchool x1
ExpeditionWeaponSmith x1
Farm x11
Farmfield x6
Finesmith x1
FishFarm x3
Fisher x5
FloatingResidence x6
FlyingHouse x2
Forester x11
Foundry x1
Friary_Mini x1
Garrison x6
GhostGeneralGarrison x1
GiantBarrel x1
GiantTreeOfHope x1
GiftChristmasTree x3
GingerbreadStorage x3
GoldMine x3
GoldSmelter x2
GoldTower x3
GraniteMason x5
Harbour x1
HauntedMansion_pop x1
HeartTree x1
Hunter x8
IceSkatingLake x1
ImprovedBakery x1
ImprovedBronzeWeaponsmith x2
ImprovedButcher x1
ImprovedFarm x3
ImprovedLettersmith x1
ImprovedMill x2
ImprovedSilo x2
ImprovedWatermill x4
IronMine x11
IronMine_Mini x2
IronSmelter x4
IronWeaponsmith x2
KrampusPit x1
Lettersmith x1
Logistics x1
Longbowmaker x1
LoversStatue x1
MahoganySawmill x1
MarbleMason x7
Mason x4
Mayorhouse x1
Miller x4
MineDepletedDepositChristmasResource x4
MineDepletedDepositCorn x6
MineDepletedDepositGranite x2
MineDepletedDepositMarble x1
MineDepletedDepositStarfallStarShards x5
MineDepletedDepositStone x1
MountainClanColossus x1
NobleResidence x33
OasisResidence x1
OilMill_Mini x1
Oilmill x1
Ornamentalsmith x1
Ostereierbaum_blue x1
PapermillAdvanced x1
PapermillIntermediate x2
PapermillSimple x2
PirateResidence x4
PlatinumSmelter x2
PlatinumWeaponsmith x2
Powderhut x1
ProvisionHouse x1
ProvisionHouse2 x1
PumpkinFieldDeco x2
RabbitBreeding x1
RangerHut x1
RealWoodCutter x8
RealWoodForester x10
RealWoodSawmill x6
SaddleMaker x1
Sawmill x2
School_Mini x1
Shepard x1
SnackStand x1
SoccerChampionTrophy x1
SpecialWarehouse x8
Stable x3
StarCoin3GeneralGarrison x1
StarGeneral2Garrison x1
StarfallAirship x1
SteelForge x2
SteelWeaponsmith x1
SunflowerFarm x1
Tavern x1
TipiResidenceColor2 x1
TipiResidenceWhite1 x1
TitaniumSmelter x1
TitaniumWeaponsmith x1
Toolmaker x6
TrainingGrounds x1
TransportAdmiralGarrison x1
VillageSchool x1
WagonMaker x1
Warehouse x21
Watermill x4
Weaver x1
Wheelmaker x1
WhiteCastle x1
WitchTower_Deco x3
WoodCutter x11
benchGold x1
benchIronGold x1
coal_workyard x4
decoration_mountain_peak x1
flowerbed_blue x8
flowerbed_red x2
flowerbed_yellow x1
lanternSingle x1
pvp_progression_building x1
silo x5
statueRiding x1
statueSoldier x1
statueTrader x4
stoneFlowered x3
tent_traitors_leader_Deco x3
vases x2
```

## Tribute variants

Tributes can be suffixed several ways — all surface as the same family
of buildings (mini decorative versions placed on the player's island):

- `*_mini`        — `AdvancedToolmaker_mini`, `BalloonMarket_mini`
- `*_Mini`        — `BronzeMine_Mini`, `Coinage_Mini`, `Friary_Mini`,
                    `IronMine_Mini`, `OilMill_Mini`, `School_Mini`
- `*_Mini_Gold`   — `Bookbinder_Mini_Gold`, `Butcher_Mini_Gold`

The Buffs panel groups all three under a single "Tributes" section and
renders them as "X Tribute" (e.g. `Bookbinder_Mini_Gold` → "Bookbinder
Tribute").

## Casing gotchas

| Skin (wire)    | Naive guess     | Notes                                |
|----------------|------------------|--------------------------------------|
| `Oilmill`      | `OilMill`        | lowercase `mill`                     |
| `Farmfield`    | `FarmField`      | lowercase `field`                    |
| `benchGold`    | `BenchGold`      | leading lowercase                    |
| `flowerbed_*`  | `Flowerbed*`     | leading lowercase + underscore       |
| `statue*`      | `Statue*`        | leading lowercase                    |
| `vases`        | `Vase`           | lowercase + plural                   |
| `Dark_Castle_01_Deco` | `DarkCastle_01_Deco` | underscore between Dark and Castle |
| `Barracks3`    | `Barracks_3`     | no underscore — survives normalizer  |
| `WitchTower_Deco` | `WitchTower`  | `_Deco` suffix is part of the skin   |
