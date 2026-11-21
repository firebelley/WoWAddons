# Nameplates remain the only enemy list

No WoW client API returns a threat table, and no unit token lists every enemy fighting the group. Every addon found that shows threat on several mobs at once gets those mobs from `nameplate1..40`, except TWThreat, whose Turtle WoW server sends the list. So FireThreat's scan of `nameplate1..40` with `UnitThreatSituation` is the standard technique, not a workaround. The mainstream meters (Omen3, ThreatClassic2, Details Tiny Threat, Skada, KLHThreatMeter) avoid the problem by showing **one mob**, picked from `target`/`targettarget`/`focus`. Raid frames avoid it a different way, with the mob-less `UnitThreatSituation(unit)`, which says "this unit has aggro on something" but not which mob or how many. Every other token (target, focus, mouseover, softenemy, `partyNtarget`/`raidNtarget`, `bossN`) only reaches mobs someone is already looking at. Those tokens can supplement nameplates but never replace them. Four improvements are worth making, in this order:
1. A mob-less "aggro you can't see" alarm.
2. `UnitThreatLeadSituation` for tank rows. Blizzard's own nameplates use it.
3. Telling "another tank has it" apart from "a squishy has it".
4. A test of whether `"target"` returns *readable* threat numbers on Forever. ThreatClassic2's Forever build does arithmetic on those numbers without any guard.

Scanning group members' targets is the weakest supplement. It adds little in 5-mans, and secret unit comparisons on restricted maps may make it impossible to de-duplicate.

## Three designs exist, and only one shows many mobs

The dedicated meters all show one mob, because Blizzard's threat API only answers for a (unit, mob) pair. Each meter uses the cheapest token that names the mob the user cares about:
- **Omen3**: `FindThreatMob()` walks `{"target","targettarget"}`, or `{"focus","focustarget","target","targettarget"}` when focus is enabled. It polls every 0.5 s because no event fires for a targettarget change ([Omen source](https://www.wowace.com/projects/omen-threat-meter/source), Omen.lua L1730-1815).
- **ThreatClassic2**: on Forever it is forced to `TC2.playerTarget = "target"`. Its code comment says "mainline returns secret threat values for targettarget" ([TC2 core.lua L727-739](https://github.com/dfherr/ThreatClassic2/blob/9f4a4c3592ef31f15e8ef1a4cb708d8bda3e2fbe/core/core.lua#L727-L739)).
- **Details Tiny Threat** uses `"focus"` or `"target"` ([Details_TinyThreat.lua](https://github.com/Tercioo/Details-Damage-Meter/blob/2efa4b10628e0e4a91c346138cf8325e81d0a43c/plugins/Details_TinyThreat/Details_TinyThreat.lua)).
- **Skada** (which ships `Skada_Forever.toc`) uses target, then focus/focustarget, then targettarget ([Skada Threat.lua L25-38](https://github.com/zarnivoop/skada/blob/1da7ee7d4144e25384f01bf80b8436e7afc6951c/modules/Threat.lua#L25-L38)).

**KLHThreatMeter** (vanilla 1.12) had no per-mob data at all. It kept one running total per player, built from its own combat-log parsing and synced over addon channels, and it needed a raid officer's `/ktm mastertarget` to make that total mean anything ([KTM_Tables.lua](https://svn.grimore.org/vanilla-wow-addons/k/KLHThreatMeter/Code/KTM_Tables.lua); [Advanced Raid Commands](https://svn.grimore.org/vanilla-wow-addons/k/KLHThreatMeter/Readme/Advanced%20Raid%20Commands.txt)). **LibThreatClassic2** did store threat per player GUID per mob GUID, built from the combat log. But its public API copied Blizzard's unit-based calls, and its README now calls the library obsolete ([LibThreatClassic2.lua L1276-1690](https://github.com/dfherr/LibThreatClassic2/blob/c39ecd1baf5cf075b380f954899931fdf7575a48/LibThreatClassic2.lua#L1276-L1690)). Both combat-log designs are dead on Forever, where registering `COMBAT_LOG_EVENT_UNFILTERED` triggers ADDON_ACTION_BLOCKED.

The second design is **per-plate colouring**, and it is the one FireThreat's core shares:
- **Blizzard's nameplates** run CompactUnitFrame on each nameplate unit. For DPS they call `UnitThreatSituation("player", plate)`, and for tanks `UnitThreatLeadSituation("player", plate)` ([CompactUnitFrame.lua L588-627, forever](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)).
- **Plater** checks threat from each plate's OnUpdate tick, only for enemy NPC plates, and on Forever it takes the Midnight code path (`DF.IsAddonApocalypseWow()` is true for builds 16001-19999) ([Plater.lua L87-88, L7528-7537](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua); [fw.lua L260-267](https://github.com/Tercioo/Plater-Nameplates/blob/master/libs/DF/fw.lua)).
- **Kui Nameplates** colours from `UNIT_THREAT_LIST_UPDATE` plus `UnitThreatSituation('player', unit)` ([Kui threat.lua](https://github.com/kesava-wow/kuinameplates2/blob/master/Kui_Nameplates/elements/threat.lua)).
- **ThreatPlates** does the same ([ThreatPlates Nameplate.lua L1059-1064](https://github.com/Backupiseasy/ThreatPlates/blob/devel/event-handling-redone/Nameplate.lua)).

Blizzard's own UI never offers a multi-mob list. Its only multi-mob threat view is this per-plate colouring, plus the target-frame indicator for the one mob you have targeted ([UnitFrame.lua L982-1100, forever](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Mainline/UnitFrame.lua)).

The third design is **the multi-mob list**, the niche FireThreat occupies:
- **Lazy Threat** "reads threat from every enemy nameplate" and requires enemy plates to be on ([CurseForge](https://www.curseforge.com/wow/addons/lazythreatbyloafs)).
- **EnemyTargetList** "scans nameplates" and requires "Show All Nameplates" ([CurseForge](https://www.curseforge.com/wow/addons/enemytargetlist)).
- **Threat Board** is the closest analogue, since it is built for Forever. It says "enemy tracking relies on information exposed through the game's nameplate system", that enemies beyond nameplate range "cannot be discovered", and that clicking a row to target it is "not supported by the WoW Forever client" ([CurseForge: Threat Board](https://www.curseforge.com/wow/addons/threat-board)). That is the same wall recorded in FireThreat's header comment ([FireThreat.lua L10-16](../FireThreat/FireThreat.lua)).
- **TankThreatTracker** (Classic Era, 2026) reads live threat only from `target` and `mouseover`. It caches those readings by GUID and uses the combat log and nameplates only to decide whether a cached mob is still alive, so off-target numbers are stale snapshots. Its header lists the same failed secure-targeting attempts FireThreat went through ([TankThreatTracker.lua L4-15, L281-370](https://github.com/mathis1337/TankThreatTracker/blob/main/TankThreatTracker.lua)).
- **TWThreat** gets per-mob data from Turtle WoW's custom server packets, which no Blizzard client offers ([TWThreat.lua L797-830](https://github.com/CosminPOP/TWThreat/blob/master/TWThreat.lua)).

Midnight-era addons followed the same pattern under secret values:
- They colour from readable status.
- They pass secret numbers straight to `StatusBar:SetValue`. Cell does this explicitly because `SetSmoothedValue`'s Lua `Clamp()` would throw ([Cell UnitButton.lua L2653-2694](https://github.com/enderneko/Cell/blob/master/RaidFrames/UnitButton.lua)).
- They drop features that compare units. Threat Plates 13.0.0-beta20 "disabled off-tank detection as UnitIsUnit returns secret values" ([CurseForge file 7687607](https://www.curseforge.com/wow/addons/tidy-plates-threat-plates/files/7687607)).

No Midnight addon was found that enumerates mobs without nameplates.

## The API is strictly pairwise, so every alternative piggybacks on someone's target

Forever's API docs have no `C_ThreatList`. The Threat system contains only `GetThreatStatusColor` and `IsThreatWarningEnabled`. All per-mob queries are unit-token pairs: `UnitThreatSituation(unit, mob?)`, `UnitDetailedThreatSituation(unit, mob)`, `UnitThreatPercentageOfLead` and `UnitThreatLeadSituation` ([ThreatDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/ThreatDocumentation.lua); [UnitDocumentation.lua, forever](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)). The token list offers `nameplate1..40` as the only family that reaches mobs nobody targets ([warcraft.wiki.gg UnitId](https://warcraft.wiki.gg/wiki/UnitId)). The one query that needs no enemy token is mob-less `UnitThreatSituation(unit)`, which "reflect[s] whichever NPC unit the player unit has the highest threat against" ([wiki API_UnitThreatSituation](https://warcraft.wiki.gg/wiki/API_UnitThreatSituation)). Blizzard's raid frames, Grid2 and Cell's aggro border all use it for exactly that purpose ([Grid2 StatusThreat.lua](https://github.com/michaelnpsp/Grid2/blob/master/modules/StatusThreat.lua)).

Forever's secret predicates add three more limits:
- **Compound tokens:** results are secret "if any unit in the chain fails" the identity check ([SecretPredicatesDocumentation.lua, forever](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicatesDocumentation.lua)).
- **`UnitIsUnit` with compound tokens:** the comparison is "always secret" when it involves a compound token such as `boss1target`, on addon-restricted maps.
- **Mixed pairs:** comparing tokens like `nameplate3` against `boss1` returns nothing at all.

That second limit is what breaks de-duplication of `party1target` against your nameplate rows inside dungeons.

| Approach | Used by | Reaches untargeted mobs | Per-mob status | Forever viability | Verdict for FireThreat |
|---|---|---|---|---|---|
| `nameplate1..40` × `UnitThreatSituation` | Blizzard plates, Plater, Kui, ThreatPlates, Lazy Threat, Threat Board, FireThreat | Yes, within plate range (20-41 yd) and with enemy plates on | Yes | Confirmed readable in-game (status) | Keep as the backbone |
| `target` / `focus` | Omen3, TC2, Details, Skada, Cell aggroBar | No | Yes, one mob | Status readable; numbers *possibly* readable (TC2 does math on them) | Test for numeric % on the target row |
| `targettarget` / `focustarget` | Omen3, Skada, TC2 on Classic | No | One mob | TC2 says values are secret on mainline/Forever | Skip |
| `partyNtarget` / `raidNtarget` | Omen3 (as *unit* arg only), KTM boss detection, Lazy Threat (claimed) | Only mobs a member targets | Yes | Compound: readability and `UnitIsUnit` de-dupe unproven | Optional, raid-only, after testing |
| `mouseover` / `softenemy` | TankThreatTracker, Omen3 | No; snapshots only | One mob | Same tokens already have plates; GUID cache blocked by secret identity | Skip |
| `bossN` | none found for vanilla content | No | Yes | Unknown whether populated; boss threat *values* singled out as secret | Skip unless the test says otherwise |
| Mob-less `UnitThreatSituation(unit)` | Blizzard raid frames, Grid2, Cell | Detects aggro beyond plate range | No (one max per unit) | Single-token queries "generally not secret" | Add as an alarm |
| `UnitThreatLeadSituation(player, plate)` | Blizzard tank nameplates | Same as nameplates | Tank margin, 0-3 | Same predicate as status; needs a test | Add for tank rows |
| Combat log + addon sync | KTM, LibThreatClassic2 | Yes | Yes | Blocked | Impossible |
| Server packets | TWThreat | Yes | Yes | Turtle WoW only | Impossible |

So nameplate scanning is necessary for enumeration and there is no alternative to it, but it is not necessary for *detection*. Mob-less queries detect that something is on a given unit without knowing what. Group-target tokens can name a few extra mobs at the edge of range. Neither lists the pack a tank actually cares about.

## FireThreat already does Plater's loop; four gaps are worth closing

FireThreat's `Assess()` loops every group member and pet with `Status(who, unit)`. It finds a `holder` (any member with status ≥ 2), and when the tank's status is 2 it finds a `puller` (a member with status 1) ([FireThreat.lua L179-214](../FireThreat/FireThreat.lua)). That is broader than Plater, which loops only a `TANK_CACHE` and counts a tank as holding when status ≥ 2. Plater's "pulling_from_tank" state is the same idea as FireThreat's DPS "pulling from X" ([Plater.lua L7824-7880](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)). The status-only core is sound and matches every reference implementation. The gaps are at the edges.

**1. Mob-less aggro alarm.** After `Enemies()` builds the list, compare it against mob-less `Status(who)` for the player and each group unit:
- If you are not tanking, `Status("player") >= 2` and no listed row has `e.mine`, an enemy without a plate is on you.
- If you are tanking, a non-tank member with mob-less status ≥ 2 who is no row's `holder` has a loose mob you can't see.

This costs one extra call per group unit and pet per update, at most about 80 in a full raid, regardless of how many mobs there are. It covers plates being turned off, mobs past 41 yd, and the 40-plate cap. The query is single-token, which the Forever predicate text calls "generally not secret". It cannot say which mob, so the title bar is the right place for it ("1 hidden on Bob"), not a row. One caveat: Blizzard returns nil for this highlight when solo (`UnitInParty("player") == false`), but that check is in Blizzard's UI code, not the API ([CompactUnitFrame.lua L624-626](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)).

**2. `UnitThreatLeadSituation` for tank rows.** The function's own doc text describes it as a 0-3 state for "how far the provided unit is above the secondmost threat", and it "will always return red" when the unit isn't first. It carries the same `SecretWhenUnitThreatStateRestricted` flag as `UnitThreatSituation` ([UnitDocumentation.lua, forever](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)). Today FireThreat's tank rows go green at status 3 and yellow only at status 2, which means someone is already over 100%. With the lead state, a status-3 row can turn yellow while the lead is shrinking, before anyone overtakes. Blizzard merges 1 and 2 into one "gaining/losing" colour, which fits FireThreat's three-colour scheme ([CompactUnitFrame.lua L588-627](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)). The yellow/orange thresholds are undocumented.

**3. Another tank holding is not "loose".** A tank sees any holder as red "loose" (`RANK_LOOSE`, [FireThreat.lua L199-206](../FireThreat/FireThreat.lua)), so in a two-tank raid every mob on the off-tank flashes red. Plater and ThreatPlates give that case its own "anothertank"/"OFFTANK" state, and Blizzard draws a yellow `tankBorderColor` for it ([Blizzard_NamePlateFrameOptions.lua L61-95](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlateFrameOptions.lua)). Plater identifies tanks on Era-type clients with `UnitGroupRolesAssigned == "TANK"` or `GetPartyAssignment("MAINTANK", unit)` ([Plater.lua L1256-1360](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)). FireThreat can do the same on the `holder` and show such rows as "other tank" in green or grey. This needs no new secrets, only readable roles.

**4. Readable numbers on `"target"`.** ThreatClassic2's Forever build passes `UnitDetailedThreatSituation(unit, "target")` results straight into `rawThreatPercent / threatPercent > 1.2`, `floor(data.threatPercent + 0.5)` and `data.threatValue > 0`, with no `issecretvalue` guard ([TC2 core.lua L666-711](https://github.com/dfherr/ThreatClassic2/blob/9f4a4c3592ef31f15e8ef1a4cb708d8bda3e2fbe/core/core.lua#L660-L712)). Arithmetic on a secret value raises an error, so a maintained addon shipping that code (v2.73-v2.76 added and refined Forever support) is real but indirect evidence that `target` numbers are readable. Skada guards every return with `readable()`, so its code proves nothing either way ([Skada Threat.lua L41-56](https://github.com/zarnivoop/skada/blob/1da7ee7d4144e25384f01bf80b8436e7afc6951c/modules/Threat.lua#L41-L170)).

The docs leave the question open. The predicate text says player-vs-nameplate values are "generally not secret", yet you confirmed in-game that they are secret. The doc text understates Forever's restrictions, and only a runtime check settles this. If `target` turns out to be readable, FireThreat can print a short "87%" on the row where `UnitIsUnit(unit, "target")` is already computed ([FireThreat.lua L388](../FireThreat/FireThreat.lua)). That comparison is explicitly permitted.

**Lower-value options.** Each has a cost:
- **Group targets in raids.** Add `raidNtarget` rows for mobs with no plate. This only helps if compound tokens give readable status and you can de-duplicate them against plate rows. One untested way to de-duplicate is `C_NamePlate.GetNamePlateForUnit("raid3target")`. Retail 12.0 stopped accepting compound tokens there from tainted code, and Forever may have done the same ([Patch 12.0.0 API notes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes)).
- **Forcing plate settings.** Set `nameplateMaxDistance` to 41 out of combat, as Plater does, and turn on `nameplateShowEnemies` instead of only printing a hint. Both are zero-config wins, but they change the user's CVars ([Plater.lua L11422-11428](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)).
- **Keeping rows after a plate disappears.** Threat Board keeps rows until the mob dies or combat ends. FireThreat would have no token to query such rows, and GUID keys may be secret, so they would show stale status.

**Not worth doing:**
- **Switching from polling to events.** `UNIT_THREAT_LIST_UPDATE` fires for `target` and `nameplateX`, not for `raidXtarget` ([wiki UNIT_THREAT_LIST_UPDATE](https://warcraft.wiki.gg/wiki/UNIT_THREAT_LIST_UPDATE)). The 5 Hz OnUpdate is simpler and already covers everything.
- **Copying Plater's DPS "no tank" check on its Midnight path.** It passes an undefined global `unitId`, which silently turns the call into the mob-less form ([Plater.lua L8028-8085](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)).

## Six in-game checks settle what the source cannot

Run each in combat in both the open world and a dungeon, because addon-restricted-map rules differ there. Where FireThreat has a row for the mob, `nameplate1` stands for that mob's plate.

| # | Question | Command | Decides |
|---|---|---|---|
| 1 | Are threat numbers readable on `target` but not on a plate? | `/run print(C_Secrets.ShouldUnitThreatValuesBeSecret("player","target"), C_Secrets.ShouldUnitThreatValuesBeSecret("player","nameplate1")) local _,_,c,_,e=UnitDetailedThreatSituation("player","target") print(issecretvalue(c),issecretvalue(e))` | Option 4 (numeric % on the target row) |
| 2 | Is the lead state readable? | `/run local v=UnitThreatLeadSituation("player","nameplate1") print(v, v~=nil and issecretvalue(v))` while tanking | Option 2 |
| 3 | Does the mob-less form see an enemy without a plate? | Press V to hide enemy plates (or kite a mob past 41 yd), let it hit you, then `/run local v=UnitThreatSituation("player") print(v, v~=nil and issecretvalue(v), C_Secrets.ShouldUnitThreatStateBeSecret("player"))` | Option 1 |
| 4 | Are compound group-target tokens usable and comparable? | `/run print(UnitThreatSituation("player","party1target"), C_Secrets.ShouldUnitThreatStateBeSecret("player","party1target"), C_Secrets.ShouldUnitComparisonBeSecret("party1target","nameplate1"), C_NamePlate.GetNamePlateForUnit("party1target"))` | Group-target supplement |
| 5 | Are boss tokens populated on vanilla bosses? | `/dump UnitExists("boss1"), C_Secrets.ShouldUnitThreatValuesBeSecret("player","boss1")` during a dungeon boss | Whether `bossN` is worth a look |
| 6 | What is the plate range cap? | `/dump GetCVar("nameplateMaxDistance")`, then `/run SetCVar("nameplateMaxDistance",41)` and check a mob at about 35 yd gets a plate | Whether to force 41 |

## Conclusion

The research turns the design question around. FireThreat does not need a substitute for nameplate scanning, because none exists. Even the Forever-native Threat Board and Blizzard's own UI stop at the edge of plate range. What FireThreat lacks is a layer that knows the list is incomplete. Mob-less `UnitThreatSituation` gives that layer almost for free: compare "who has aggro on something" against "who holds a listed mob", and the difference is the enemies FireThreat cannot see.

The two biggest unknowns could each change the addon more than any enumeration trick. If test 1 shows `target` numbers are readable (as ThreatClassic2's unguarded arithmetic suggests), FireThreat can show real percentages on the mob the player is focused on. If test 2 shows the lead state is readable, tanks get the early warning Blizzard built for them.
