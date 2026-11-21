# How nameplate addons, raid/unit frames and Blizzard's UI show threat, and where they get the data

Method: shallow git clones of each addon's GitHub repo and of Gethe/wow-ui-source (`forever`, `classic_era` and `live` branches), then a grep and read of the threat code. Commit dates are as cloned on 2026-11-21:
- wow-ui-source `forever` 734f065 (2026-11-20), `classic_era` 4192ac6 (2026-10-26)
- Plater 8dec209 (2026-11-21)
- Kui Nameplates 9af9949 (2026-11-20)
- Grid2 76309b9 (2026-11-15)
- Cell 2fbdca8 (2026-08-09)
- ThreatPlates: the GitHub default branch is `devel/event-handling-redone` at 33d8426 (2022-09-20), so it is stale (see Gaps)

Line numbers below refer to those commits. Repo links: https://github.com/Gethe/wow-ui-source/tree/forever, https://github.com/Tercioo/Plater-Nameplates, https://github.com/kesava-wow/kuinameplates2, https://github.com/Backupiseasy/ThreatPlates, https://github.com/michaelnpsp/Grid2, https://github.com/enderneko/Cell

## Q1. Is nameplate scanning the standard way to enumerate multiple nearby enemies? What alternatives exist?

### Takeaway
Yes. Every per-mob threat display found here works per nameplate unit: Blizzard's own nameplates, Plater, Kui, ThreatPlates, and every multi-enemy list addon on CurseForge whose method is documented (Threat Board for Forever, EnemyTargetList). Threat Board says outright that it relies on the nameplate system. The only alternatives seen are:
- the single `target` (or focus) unit, used by Blizzard's target frame and Cell's aggro bar
- `<unit>target` chains, used by ThreatPlates' heuristic mode and in off-tank checks
- the mob-less `UnitThreatSituation(unit)` "max over all mobs" query, used by raid frames

None of these alternatives can enumerate enemies.

### Cited Findings
- Blizzard nameplates (forever branch) get per-mob threat by running CompactUnitFrame code on each nameplate unit. The enemy-nameplate option table sets `usePlayerForAggroHighlightThreat = true` (the friendly table sets `false`), and `tankBorderColor = CreateColor(1, 1, 0, .6)`. — [Blizzard_NamePlateFrameOptions.lua L61-95 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlateFrameOptions.lua)
- Each CompactUnitFrame registers `UNIT_THREAT_SITUATION_UPDATE` and `UNIT_THREAT_LIST_UPDATE` via `RegisterUnitEvent(..., unit, displayedUnit)`. SITUATION_UPDATE triggers aggro highlight, aggro flash, health border and health colour updates. LIST_UPDATE re-colours only when `considerSelectionInCombatAsHostile` is set. — [CompactUnitFrame.lua L131-140, L349-350 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)
- Plater (all flavours) runs its threat check from the per-plate OnUpdate tick, not from threat events: `if (PLAYER_IN_COMBAT) then if (unitFrame.CanCheckAggro) then Plater.UpdateNameplateThread (unitFrame)`. `CanCheckAggro` is true only for enemy NPC plates (`actorType == ACTORTYPE_ENEMY_NPC`). — [Plater.lua L7528-7537, L4337](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- Kui Nameplates colours threat from `UNIT_THREAT_LIST_UPDATE` (registered per unit) plus the plate `Show` message, calling `UnitThreatSituation('player', unit)`. — [Kui elements/threat.lua L20-66](https://github.com/kesava-wow/kuinameplates2/blob/master/Kui_Nameplates/elements/threat.lua)
- ThreatPlates updates on `UNIT_THREAT_LIST_UPDATE`, looking up the plate for the event unit (`Addon:UNIT_THREAT_LIST_UPDATE(unitid) ... GetThreatPlateForUnit(unitid)`). — [ThreatPlates Nameplate.lua L1059-1064](https://github.com/Backupiseasy/ThreatPlates/blob/devel/event-handling-redone/Nameplate.lua)
- ThreatPlates has a non-threat-API heuristic mode (`UseThreatTable` off, or `UseHeuristicInInstances`). It treats the mob as "HIGH" if `UnitIsUnit(unitid.."target", "player")`, else "LOW", and skips the check while the mob is casting (`not unit.isCasting`). — [ThreatPlates Modules/Threat.lua L188-205](https://github.com/Backupiseasy/ThreatPlates/blob/devel/event-handling-redone/Modules/Threat.lua)
- Threat Board, built for WoW Forever (flavour Forever, game version 1.60.1, updated 2026-11-17): "Automatically tracks hostile enemies as they enter nameplate range". "Enemy tracking relies on information exposed through the game's nameplate system". "Enemies outside the game's available nameplate range cannot be discovered". Row clicking to target is "not supported by the WoW Forever client". "Some health, threat, cast, and aura information is restricted by the game API". — [CurseForge: Threat Board](https://www.curseforge.com/wow/addons/threat-board)
- EnemyTargetList (MoP Classic 5.5.x) "scans nameplates and displays enemy info on customizable bars", colours bars by threat status and by group roles, and requires enemy nameplates plus "Show All Nameplates" to be enabled. — [CurseForge: EnemyTargetList](https://www.curseforge.com/wow/addons/enemytargetlist)
- Enemy List (TBC Classic flavour; also claims to load on Era, Wrath, Cata and Retail) shows "every enemy fighting you or your group" with threat %, raw value, runner-up threat bars, casts and each enemy's target. It has nameplate highlight/threat overlay features and raises nameplate range toward the client max. Its page does not say how it enumerates enemies. — [CurseForge: Enemy List](https://www.curseforge.com/wow/addons/enemy-list)
- Other nameplate-attached threat addons appear in search results (Proto Threat: a threat list per nameplate plus a focus list; Senpai Plates; Nyari Threat; TankThreat; Detholusin's Threat Plates). I did not open their pages. — [search results: Proto Threat](https://www.curseforge.com/wow/addons/proto-threat), [Senpai Plates](https://www.curseforge.com/wow/addons/senpai-plates), [Nyari Threat](https://www.curseforge.com/wow/addons/nyari-threat)
- Cell's raid-frame "aggroBar" avoids enumeration entirely: it queries only the player's current target, `UnitDetailedThreatSituation(unit, "target")`, refreshed on `PLAYER_TARGET_CHANGED` and `UNIT_THREAT_LIST_UPDATE`. — [Cell RaidFrames/UnitButton.lua L2680-2694, L3195-3204](https://github.com/enderneko/Cell/blob/master/RaidFrames/UnitButton.lua)

### Inferences
- For a list of all nearby enemies there is no non-nameplate unit source besides `target`, `focus`, `mouseover`, `softenemy` and `<groupunit>target`. Without the combat log, nameplates are effectively the only way to enumerate many mobs, so FireThreat's nameplate1..40 scan matches what the Forever-specific Threat Board does.
- A useful supplement is to also check `partyNtarget`/`raidNtarget` (and `target`/`focus`) for enemies whose nameplate isn't shown. Dedupe with `UnitIsUnit` against existing nameplate units, since GUIDs may be restricted. This catches mobs that group members are fighting beyond your nameplate range. It is an inference: none of the addons examined do this for enumeration; they use target chains only for off-tank checks.

### Gaps
- Enemy List's and Proto Threat's enumeration method could not be confirmed (no source read).
- Platynator: no repo found (github.com/TheMouseNest/Platynator returned "not found"; the web search returned nothing relevant). ElvUI's nameplate threat (oUF ThreatIndicator) was not examined.

## Q2. How do nameplate addons decide "I'm tanking / off-tank has it / I'm about to pull"?

### Takeaway
All of them start from `UnitThreatSituation("player", plateUnit)` (status 0-3, or nil if not on the threat table) and branch on whether the player is a tank:
- **DPS colours:** 3 or 2 means "you have aggro" (bad), 1 means "about to pull", 0 is fine.
- **Tank colours:** 3 is secure, 2 is "losing it", nil/0/1 means "not tanking".
- **Off-tank:** shown when a different group tank has status >= 2 on the same mob. Plater loops a cache of group tanks with `UnitThreatSituation(tank, plate)`. Kui and ThreatPlates instead check `plate.."target"`: is the mob targeting a group member with role TANK, or a pet/player-controlled unit?
- **New Blizzard API:** `UnitThreatLeadSituation` (tank margin over second place) exists on Forever and Classic Era and is what Blizzard's nameplates use for tanks.

### Cited Findings

**Blizzard (forever and classic_era branches, identical logic)**

- **DPS.** On enemy nameplates, `GetAggroHighlightThreatSituation` returns `UnitThreatSituation("player", frame.displayedUnit)` when the player isn't a tank ("Show DPS how close they are to pulling threat").
- **Tanks.** For tanks it returns `UnitThreatLeadSituation("player", frame.displayedUnit)` ("Show Tanks how close they are to losing threat to the second highest threat or red if they're not the highest threat").
- **Solo.** It returns nil unless the player is in a party (`if UnitInParty("player") == false then return nil`).
- **Colours.** Statuses 1 and 2 both map to `GAINING_THREAT_COLOR`, 3 maps to `HIGH_THREAT_COLOR`, and anything else to `NO_THREAT_COLOR`. The comment reads "reduce visual language to 'You're about to gain or lose threat'".
- Sources: [CompactUnitFrame.lua L588-627 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua); the same code is at L609-622 of [classic_era CompactUnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)

**Blizzard API docs and helpers (forever branch)**

- **`UnitThreatLeadSituation(unit, mobGUID)`**, documented on forever: "Returns a threat state (0-3; representing none, yellow, orange, red) that indicates how far the provided unit is above the secondmost threat on the provided mob. If the unit is not first on threat, will always return red. Can return nil if the provided mob does not exist." Flags: `SecretWhenUnitThreatStateRestricted = true`, `SecretArguments = "AllowedWhenUntainted"`. — [UnitDocumentation.lua (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- **Off-tank border.** Blizzard's "another tank has it" border (`tankBorderColor`, yellow, alpha 0.6) shows if all of these hold: the player is in a group, `PlayerUtil.IsPlayerEffectivelyTank()` is true, and `UnitDetailedThreatSituation("player", mob)` gives `isTanking == false` with a non-nil status (on the threat table). It never identifies who the other tank is. — [CompactUnitFrame.lua L978-985 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)
- **Aggro flash.** It fires when `isTanking` from `UnitDetailedThreatSituation("player", mob)` flips into the wrong state for the role ("Flash if threat is transitioning to the state it shouldn't be in for the current role (e.g. DPS is now tanking)"). It skips the first valid value so solo DPS don't flash on pull. — [CompactUnitFrame.lua L997-1030 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)
- **Tank detection.** `PlayerUtil.IsPlayerEffectivelyTank()` checks, in order:
  1. `UnitHasEffectivelyTankAura("player")`
  2. on spec systems, spec role when the assigned role is NONE
  3. otherwise `UnitGroupRolesAssigned("player") == "TANK"`
  — [Blizzard_SharedXML/UnitUtil.lua L109-121 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_SharedXML/UnitUtil.lua)

**Plater**

- **Forever uses the Midnight code path.** `IS_WOW_PROJECT_MIDNIGHT = DF.IsAddonApocalypseWow()`, and `DF.IsAddonApocalypseWow()` returns `buildInfo >= 120000 or DF.IsForeverWow()`. `IsForeverWow` is true for builds 16001-19999. — [Plater.lua L87-88](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua); [libs/DF/fw.lua L260-267](https://github.com/Tercioo/Plater-Nameplates/blob/master/libs/DF/fw.lua)
- **Midnight/Forever path.** It calls `UnitDetailedThreatSituation("player", unit)`, then overrides it: `threatStatus = UnitThreatSituation("player", self.displayedUnit); isTanking = (threatStatus or 0) >= 2`. "Tanking" therefore means status 2 or 3, derived from the readable status only. — [Plater.lua L7803-7807](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- **Player is a tank and not tanking**, mob in combat, in a raid:
  - It loops `TANK_CACHE`. Each other tank must pass `UnitExists(tank) and UnitIsVisible(tank) and not UnitIsUnit("player", tank)`. On Midnight/Forever it reads `UnitThreatSituation(tank, self.displayedUnit)`, guarded by `issecretvalue`, and counts the tank as tanking if status >= 2 ("as the other tank may not be targeted due to spell-casts, we need to check the threat situation for tanks").
  - If one is found, the plate gets the "anothertank" colour. If the player's own status is 1 while the other tank's is >= 2, it gets "pulling_from_tank" instead (the off-tank is about to accidentally taunt by damage).
  - If no tank is found: "noaggro". Outside a raid, a non-tanking tank always gets "noaggro".
  - Sources: [Plater.lua L7824-7880](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- **Player is a tank and tanking.** Status 3 is "aggro" (good), 2 is "pulling" plus an optional glow, anything else is "noaggro". — [Plater.lua L7905-7925](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- **DPS.**
  - Tanking (status 2 or 3) gets the "aggro" colour, or a separate "solo" colour when not grouped (`profile.dps.use_aggro_solo`). A body flash shows on first gaining aggro in an instance.
  - Status 1 is "pulling" plus a glow. Status 0 is "noaggro".
  - Status nil with the mob in combat is "noaggro". Status nil with the mob out of combat is "nocombat", with an optional alpha.
  - Sources: [Plater.lua L7928-8010](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- **DPS "mob not on a tank" warning** (`aggro_can_check_notank`, default false; party/raid instances only):
  - Non-Midnight path: it compares `UnitName(self.targetUnitID)` (the mob's target) against `TANK_CACHE` names. It then rules out false positives from spell-cast retargeting by checking `UnitThreatSituation(tankUnit, self.displayedUnit) >= 2` for each tank.
  - Midnight/Forever path: it calls `UnitThreatSituation(unit, unitId)`, but `unitId` is not a local in that function (the only `local unitId` declarations, L1414 and L1471, are in other functions). It therefore appears to be a nil global, which makes the call the mob-less "max over all mobs" form. That looks like a bug: "tank has aggro" becomes true if the tank is tanking anything.
  - Sources: [Plater.lua L8028-8085](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua); [Plater_DefaultSettings.lua L3226](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater_DefaultSettings.lua)
- **Plater's tank cache.**
  - `RefreshTankCache()` iterates `raid1..N` when in a raid. In a party it does so only inside 5-man dungeons (`Plater.ZoneInstanceType == "party"`), for `party1..N-1`.
  - It adds members where `IsUnitEffectivelyTank(unit)`. On Midnight/Forever the cache is keyed by unit token; elsewhere by name.
  - It is refreshed on roster and zone changes and on entering combat.
  - On Era-type clients, `IsUnitEffectivelyTank` uses `UnitGroupRolesAssigned == "TANK"` or `GetPartyAssignment("MAINTANK", unit)`.
  - Sources: [Plater.lua L1256-1360](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- **Plater's player-tank check on vanilla-type clients.**
  - It uses the assigned role or MAINTANK when available.
  - The fallback is class/stance/buff based: warrior Defensive Stance (form 18) or a shield; druid bear forms 5/8; paladin Righteous Fury 25780/407627; SoD rune buffs for rogue 400015/400016, warlock 403789 and shaman 408680.
  - There is a manual toggle, `Plater.ToggleThreatColorMode()` / `tank_threat_colors`, for non-Wrath/MoP classic.
  - Sources: [Plater.lua L1163-1250, L1280-1290](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- **Values exposed to scripts.** Plater exposes `namePlateThreatIsTanking`, `namePlateThreatStatus`, `namePlateThreatPercent`, `namePlateThreatOffTankIsTanking` and `namePlateThreatOffTankName`, so user scripts and mods build on the same per-plate data. — [Plater.lua L7809-7817](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)

**Kui Nameplates**

- **Glow states from `UnitThreatSituation('player', unit)`.** Status 3 is "tanking" (red glow), status 1-2 is "transition" (orange), status 0 is "in table" (no glow), and nil means not on the table. — [Kui elements/threat.lua L26-60](https://github.com/kesava-wow/kuinameplates2/blob/master/Kui_Nameplates/elements/threat.lua)
- **Tank-mode off-tank check.** If the player's status is not 3, it reads `unit..'target'`. The mob counts as off-tanked if that unit is not the player and either:
  - is in the party/raid with `UnitGroupRolesAssigned == 'TANK'`, or
  - is a non-player but player-controlled unit (pet, vehicle, totem).
- **When it runs.** Only when grouped and the player is a tank: by spec on retail, by `UnitGroupRolesAssigned('player')` on classic, or by a force option.
- Sources: [Kui plugins/tankmode.lua L108-178](https://github.com/kesava-wow/kuinameplates2/blob/master/Kui_Nameplates/plugins/tankmode.lua)

**ThreatPlates (2022 devel branch)**

- **Status to levels.** It maps `UnitThreatSituation("player", unit.unitid)` to threat levels via `THREAT_REFERENCE`.
- **Off-tank check** (when the player's status is < 2 and the style is tank): it checks `unitid.."target"`. If that target is a player or player-controlled and has `UnitThreatSituation(target_unit, unit.unitid) > 1`, then the level becomes "OFFTANK" when the target is one of:
  - a TANK-role group member other than the player
  - the player's pet
  - a tank-like creature (Black Ox Statue 61146, Treants 103822, Earth Elemental 95072)
- **Lost target.** If the mob loses its target, the last off-tank state is kept ("we assume that the mob is still securely off-tanked").
- Sources: [ThreatPlates Modules/Threat.lua L66-186](https://github.com/Backupiseasy/ThreatPlates/blob/devel/event-handling-redone/Modules/Threat.lua)
- **Threat widget numbers.** These use `UnitDetailedThreatSituation` for the player and for every `partyN`/`raidN` and `partypetN`/`raidpetN` against the plate unit. When tanking it shows the gap to the second-highest; when not tanking it shows the player's own scaled %. This needs readable numbers, so it would not work with Forever's secret values. — [ThreatPlates Widgets/ThreatWidget.lua L140-230](https://github.com/Backupiseasy/ThreatPlates/blob/devel/event-handling-redone/Widgets/ThreatWidget.lua)

### Inferences
- FireThreat's approach is the same core pattern used by Plater, Kui, ThreatPlates and Blizzard: `UnitThreatSituation(player, nameplateN)` with role-based colouring. Two cheap, readable-status-only refinements from these addons:
  1. **Off-tank:** loop group tanks with `UnitThreatSituation(tankUnit, plate) >= 2` (Plater), or check `UnitIsUnit(plate.."target", groupTank)` (Kui/ThreatPlates).
  2. **"Off-tank about to taunt by damage":** player status 1 while another tank has >= 2 (Plater's "pulling_from_tank").
- Blizzard's design choice to merge statuses 1 and 2 into one "gaining/losing" colour suggests a simple three-colour scheme is enough.
- `UnitThreatLeadSituation` is a readable-status tank-margin signal (unless the state is restricted) that FireThreat could use instead of secret percentages to show "tank is about to lose it".

### Gaps
- Whether `UnitThreatLeadSituation` is callable from tainted addon code on Forever, and whether it returns a non-secret value there, is not proven. Its doc flag is `SecretWhenUnitThreatStateRestricted`, the same flag as UnitThreatSituation, so it presumably behaves the same way, but this needs an in-game test.
- The current ThreatPlates release code (likely hosted on another branch or host) was not checked.

## Q3. Raid-frame aggro: what does `UnitThreatSituation(unit)` with no mob return, and does it reveal which or how many enemies?

### Takeaway
With the mob omitted it returns the unit's single highest status across every NPC whose threat table it is on, or nil if it is on none. It is one number, with no mob identity and no count. Blizzard raid frames, Grid2 and Cell all use it only to show "this player has aggro on something".

### Cited Findings
- "If omitted, returned values reflect whichever NPC unit the player unit has the highest threat against." Status values:
  - nil = "Unit is not on (any) mobUnit's threat table"
  - 0 = less than 100%
  - 1 = over 100% but not the primary target
  - 2 = primary target but another unit is over 100%
  - 3 = primary target, securely
  - Pet threat does not count for the owner.
  - Version history: added in Classic 1.13.5, and present in retail since 3.0.2 and in forever 1.60.1.
  - Source: [warcraft.wiki.gg API_UnitThreatSituation](https://warcraft.wiki.gg/wiki/API_UnitThreatSituation)
- Forever API documentation:
  - `UnitThreatSituation(unit, mobGUID)` has `mobGUID` typed `UnitToken`, `Nilable = true`, and flags `SecretWhenUnitThreatStateRestricted = true`.
  - `UnitDetailedThreatSituation(unit, mobGUID)` requires the mob (`Nilable = false`), has `MayReturnNothing = true`, and flags `SecretWhenUnitThreatValuesRestricted = true`. It returns isTanking, status, scaledPercentage, rawPercentage, rawThreat.
  - `UnitThreatPercentageOfLead` is also `SecretWhenUnitThreatValuesRestricted`.
  - Source: [UnitDocumentation.lua (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Blizzard CompactUnitFrame: "Frames displaying raid or party members should be set up to get the max threat of the displayed unit on all units they're attacking." It does `return UnitThreatSituation(frame.displayedUnit)`. Status > 0 shows the aggro highlight. — [CompactUnitFrame.lua L624-626, L907-930 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)
- Grid2 threat status: it registers the roster event `UNIT_THREAT_SITUATION_UPDATE`. `IsActive` is `UnitThreatSituation(unit) > 0`, and the colour is indexed by status 1/2/3 (comments: "1 = not tanking, higher threat than tank / 2 = insecurely tanking / 3 = securely tanking something"). — [Grid2 modules/StatusThreat.lua](https://github.com/michaelnpsp/Grid2/blob/master/modules/StatusThreat.lua)
- Cell's aggroBlink and aggroBorder use `UnitThreatSituation(unit)` (status >= 1, coloured with `GetThreatStatusColor(status)`) on `UNIT_THREAT_SITUATION_UPDATE`.
  - Its aggroBar is the only per-mob element, and it is fixed to the player's target: `UnitDetailedThreatSituation(unit, "target")`.
  - On Midnight-type clients it handles secret values by passing the secret percentage straight to `StatusBar:SetValue` ("SetSmoothedValue is a Lua mixin whose Clamp() would throw every tick on a secret percentage. Fall back to native SetValue when the threat percent is secret").
  - Source: [Cell RaidFrames/UnitButton.lua L2653-2694](https://github.com/enderneko/Cell/blob/master/RaidFrames/UnitButton.lua)

### Inferences
- The mob-less call can tell FireThreat "this group member has aggro (3) or is about to pull (1) on some mob". That is useful as a cheap group-wide alarm that works beyond nameplate range, since it is not limited to visible plates. It cannot tell which mob, or how many.
- The `UNIT_THREAT_SITUATION_UPDATE` event fires for the group unit whose max status changed. It can serve as a trigger to rescan plates instead of polling. This is an inference from the event payload being `unitTarget` ([UnitDocumentation.lua events (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)).
- Cell's pattern (secret value into native `SetValue`) is direct precedent for showing secret threat percentages as bars on Forever.

### Gaps
- VuhDo was not examined.
- It is unknown whether the mob-less form ignores mobs outside some range. The wiki says nothing about range.

## Q4. Blizzard's own threat UI: target frame, nameplate options, threat warning, Classic Era vs Forever

### Takeaway
Blizzard's target frame shows a threat indicator plus an optional numeric % for the target only. It uses `UnitThreatSituation("player", "target")` for the colour, and `UnitDetailedThreatSituation` / `UnitThreatPercentageOfLead` for the number. These are gated by `IsThreatWarningEnabled()` (the `threatWarning` CVar) and `threatShowNumeric`. Nameplate threat display is a bitfield CVar, `nameplateThreatDisplay` (Progressive highlight / Flash / HealthBarColor). It exists in both the forever and classic_era branches, where both share the same CompactUnitFrame threat logic.

### Cited Findings
- `UnitFrame_UpdateThreatIndicator` (forever):
  - Colour status is `UnitThreatSituation(feedbackUnit, unit)`, or `UnitThreatSituation(feedbackUnit)` when they are the same unit. It is shown if `IsThreatWarningEnabled() and not UnitIsDead(unit)` and status > 0, coloured by `GetThreatStatusColor(status)`.
  - The numeric display shows when `ShowNumericThreat()` (CVar `threatShowNumeric`) is on and the unit is not a "minus" mob. It is `rawPercentage` from `UnitDetailedThreatSituation`, or `UnitThreatPercentageOfLead` if tanking, formatted `"%1.0f%%"`.
  - Tanks that lost threat are recoloured orange "to more closely match nameplate behavior".
  - It updates on `UNIT_THREAT_SITUATION_UPDATE`.
  - Sources: [UnitFrame.lua L982-1100 (forever Mainline)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Mainline/UnitFrame.lua); TargetFrame calls it with `self.feedbackUnit` ([TargetFrame.lua L493 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Mainline/TargetFrame.lua))
- The classic_era branch has the identical function in `Blizzard_UnitFrame/Classic/UnitFrame.lua` (L893-950) and TargetFrame.lua L429. — [classic_era UnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_UnitFrame/Classic/UnitFrame.lua)
- Forever's Threat system doc lists only `GetThreatStatusColor(gameErrorIndex)` (flag `SecretArguments = "AllowedWhenUntainted"`) and `IsThreatWarningEnabled()`. The unit threat queries live in the Unit docs. — [ThreatDocumentation.lua (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/ThreatDocumentation.lua)
- The "Display Aggro Warning" dropdown (`threatWarning`: 0 Never, 1 In instance, 2 In party, 3 Always) and the "Show Aggro Percentages" checkbox (`threatShowNumeric`) are added to Classic settings only when `ClassicExpansionAtLeast(LE_EXPANSION_WRATH_OF_THE_LICH_KING)`. In the classic_era branch's settings code, Era/vanilla therefore does not get these options in the settings UI. — [classic_era InterfaceOverrides.lua L108-125](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/Classic/InterfaceOverrides.lua)
- Nameplate threat display:
  - `NamePlateConstants.THREAT_DISPLAY_CVAR = "nameplateThreatDisplay"` is read as a bitfield. `displayAggroFlash` is bit `Enum.NamePlateThreatDisplay.Flash`, `displayAggroHighlight` is `.Progressive`, and `displayThreatHealthBarColor` is `.HealthBarColor`.
  - The settings panel exposes these as three checkboxes, created when `C_CVar.GetCVar("nameplateThreatDisplay")` exists.
  - Sources: [Blizzard_NamePlateConstants.lua L5](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlateConstants.lua); [Blizzard_NamePlateUnitFrame.lua L646-658](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlateUnitFrame.lua); [Settings Nameplates.lua L656-680 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/Nameplates.lua); the same exists at L630-648 in [classic_era Nameplates.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/Nameplates.lua)
- The nameplate visibility CVars `nameplateShowEnemies` and `nameplateShowAll` ("automode") are Settings checkboxes. The Commentator addon sets `threatWarning` to 0. — [Settings Nameplates.lua L461-467 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/Nameplates.lua); [Blizzard_Commentator Classic L241-264](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_Commentator/Classic/Blizzard_Commentator.lua)

### Inferences
- Blizzard's own UI never shows a multi-enemy threat list. Its only multi-mob threat view is the colouring of each nameplate, so a list window like FireThreat's goes beyond anything Blizzard provides.
- Because Blizzard's code is untainted, it can format secret percentages (`format("%1.0f")`). Addons on Forever cannot, which explains why Threat Board says it "doesn't calculate unavailable values".

### Gaps
- Default values of `nameplateThreatDisplay` and `threatWarning` on Forever are not in the Lua source (they are C-side CVar defaults).

## Q5. What happens when enemy nameplates are disabled or out of range?

### Takeaway
Nameplate-based displays simply can't see those enemies. Addons respond in three ways:
- requiring or forcing nameplate CVars on
- raising `nameplateMaxDistance` toward the client cap (41 on Classic-type clients, 60 on retail in Plater's settings)
- keeping enemies that already left range in the list until they die or combat ends (Threat Board)

The distance cap for vanilla-type clients was historically 20 yards and reportedly rose to 41 in July 2026.

### Cited Findings
- Plater forces `SetCVar("nameplateMaxDistance", 60)` on retail and 41 elsewhere (including Forever and Era), and tracks `nameplateMaxDistance` among the CVars it manages. — [Plater.lua L11422-11428, L1540](https://github.com/Tercioo/Plater-Nameplates/blob/master/Plater.lua)
- Threat Board: "Enemies outside the game's available nameplate range cannot be discovered". It keeps enemies after they leave range, visible "until they die or the encounter ends". — [CurseForge: Threat Board](https://www.curseforge.com/wow/addons/threat-board)
- EnemyTargetList requires enemy nameplates and "Show All Nameplates" on and recommends max distance 41. On login it checks these settings and offers a popup to change them. — [CurseForge: EnemyTargetList](https://www.curseforge.com/wow/addons/enemytargetlist)
- Enemy List raises nameplate range toward the client maximum. — [CurseForge: Enemy List](https://www.curseforge.com/wow/addons/enemy-list)
- Warcraft Tavern (2026-07-23): "all variants of vanilla WoW Classic have received the ability to see character nameplates from a distance of 41 yards", up from 20 yards (Classic Era, Hardcore, SoD). Whether it was intentional was unclear. — [Warcraft Tavern](https://www.warcrafttavern.com/wow-classic/news/41-yard-nameplates-have-been-added-to-classic-era-hardcore-sod/)
- Older Blizzard forum threads report Classic Era being hard-locked to 20 yards despite the slider/CVar, and conflict with the above, likely because they predate the change. — [Blizzard forums: Nameplate range](https://us.forums.blizzard.com/en/wow/t/nameplate-range/1666121); [Max Target Distance of 20 yards](https://us.forums.blizzard.com/en/wow/t/max-target-distance-of-20-yards/1735944)
- Blizzard's own tutorial code turns on `nameplateShowEnemies` (`SetCVar("nameplateShowEnemies", 1)`), showing that enemy plates can be off by default for new players. — [Blizzard_Tutorial.lua L23 (forever)](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_BoostTutorial/Blizzard_Tutorial.lua)

### Inferences
- For a zero-config FireThreat, the precedents are (1) Plater's silent force of `nameplateMaxDistance` = 41 and (2) EnemyTargetList's login check, with `nameplateShowEnemies` turned on if it's off. Threat Board's "retain rows after a plate disappears until the mob dies or combat ends" avoids rows flickering at the range edge. Retained rows can only show last-known status, because without a unit token the mob can't be queried. The only exception is when it is reachable as `target`, `focus` or `groupNtarget`.
- Mobs fighting a group member beyond nameplate range can only be seen through `partyNtarget`/`raidNtarget`, or flagged indirectly by the mob-less `UnitThreatSituation(groupUnit)` (Q3).

### Gaps
- No official Blizzard source was found for the Forever client's `nameplateMaxDistance` default or cap (warcraft.wiki.gg's CVar_nameplateMaxDistance page returned 404). Verify in game with `/dump GetCVar("nameplateMaxDistance")` and by testing higher values.
- I found no source on whether the `nameplateShowAll` / `nameplateShowEnemies` settings affect whether nameplate unit tokens exist, as opposed to only plate visibility. Addons that hide Blizzard plates still receive `NAME_PLATE_UNIT_ADDED`, but I did not find a citable statement about this.
