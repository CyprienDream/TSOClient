# Building skin → display reference

Captured from a live `BUILDINGS` payload (533 buildings on the player's main
island). Use this as the canonical source when adding entries to
`TSOClient/Resources/Data/building-categories.json` — the raw `skin` strings
don't always match the in-game UI name (e.g. **Copper Mine** is `BronzeMine`,
**Copper Smelter** is `BronzeSmelter`). Re-capture and update this file when
the game ships new buildings.

`skinBase` is the raw `skin` with any trailing `_<digits>` stripped
(`BuildingsStore.swift`). Anything ending in `_Mini` / `_Mini_Gold` is a
tribute-style mini and keeps its suffix (the regex only strips digits).

## Captured skin counts

```
AdmiralGarrison x4                                       remove
AdvancedToolmaker x2                                     building
AdvancedToolmaker_mini x1                                tribute
AdventureBookbinder x2                                   bookbinder
AirshipExcelsior x1                                      remove
ArchebuseMaker x1                                        weapon
Bakery x5                                                bakery
BalloonMarket_mini x1                                    tribute
Barracks x1                                              barracks
Barracks3 x1                                             barracks
BlackTree_Purple x1                                      remove
BoatHouse x2                                             remove
Bonechurch_Pop x6                                        remove
Bookbinder x1                                            bookbinder
Bookbinder_Mini_Gold x1                                  tribute
Bowmaker x2                                              weapon
Brewery x8                                               brewery
BronzeMine x6                                            copper mine
BronzeMine_Mini x1                                       tribute
BronzeSmelter x4                                         copper smelter
BronzeWeaponsmith x1                                     weapon
Bungalow x1                                              remove
Butcher x5                                               butcher
Butcher_Mini_Gold x1                                     tribute
CannonForge x1                                           weapon
Carpenter x1                                             weapon
ChristmasBakery x1                                       remove
Coinage x2                                               coinage
Coinage_Mini x1                                          tribute
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
GoldMine x3                                              gold mine
GoldSmelter x2                                           gold smelter
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
IronMine x11                                             iron mine
IronMine_Mini x2                                         tribute
IronSmelter x4
IronWeaponsmith x2
KrampusPit x1
Lettersmith x1
Logistics x1
Longbowmaker x1
LoversStatue x1
MahoganySawmill x1
MarbleMason x7
Mason x4                                                 stone mason
Mayorhouse x1
Miller x4                                                mill
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
RabbitBreeding x1                                        rabbit retreat
RangerHut x1
RealWoodCutter x8                                        hardwood cutter
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
SteelForge x2                                            steel smelter
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
WoodCutter x11                                           pinewood cutter
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

## Notable name/skin mismatches

| In-game name        | Raw `skin`        |
|---------------------|-------------------|
| Copper Mine         | `BronzeMine`      |
| Copper Smelter      | `BronzeSmelter`   |
| Stone Mason         | `Mason`           |
| Hardwood Cutter     | `RealWoodCutter`  |
| Pinewood Cutter     | `WoodCutter`      |
| Mill                | `Miller`          |
| Steel Smelter       | `SteelForge`      |
| Rabbit Retreat      | `RabbitBreeding`  |
| Silo                | `silo` *(lowercase)* |
