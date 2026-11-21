# WoW API: enemy unit tokens, threat API, and Midnight / Forever secret values

Scope note: "Forever" = WoW Forever client 1.60.1 (wow-ui-source branch `forever`, UI flavor folder `Camelot`). "Retail" = Midnight 12.x (wiki currently lists retail 12.1.5, build 69848). "Classic Era" = 1.15.9. Doc entries below were pulled directly from the three branches on 2026-11-21.

## 1. Which unit tokens can refer to enemies, and can any of them list every enemy?

### Takeaway
No unit token or API lists every enemy that is in combat with the group. The only token family that lists many enemies is `nameplate1..40`, which is limited by range and settings. Every other path goes through someone's target (`target`, `focus`, `mouseover`, `softenemy`, `partyNtarget`, `raidNtarget`, `partypetNtarget`) or through `bossN`, which only exists during encounters. A mob that no group member targets and that has no nameplate cannot be reached by any token. De-duplicating by GUID is unreliable when restrictions apply. `UnitIsUnit` works for simple token pairs but not for compound ones on restricted maps.

### Cited Findings
- Token list from the wiki: `target`, `focus` (added 2.0.1), `mouseover` ("the unit under the cursor, or the most recent one"), `partyN` 1–4, `partypetN`, `raidN` 1–40, `raidpetN` (added 1.5.0), `bossN` 1–8 "active encounter bosses... if available" (added 3.3.0), `arenaN` 1–5, `nameplateN` 1–40 (added 7.0.3; "cannot be used with spell targeting or /target"), `softenemy`/`softfriend`/`softinteract` plus `anyenemy`/`anyfriend`/`anyinteract` (added 10.0.0; `any*` resolves to the locked target first, then the soft target), and `npc`/`questnpc` (only during an active interaction such as gossip, merchant or quest). Compound tokens chain by appending `target` (e.g. `pettarget`). The wiki gives no per-flavor (Classic) availability. — [warcraft.wiki.gg UnitId](https://warcraft.wiki.gg/wiki/UnitId)
- The Forever docs define a type `UnitTokenNamePlate` for C_NamePlate functions, and `UnitTokenPvPRestrictedForAddOns` for UnitGUID, UnitHealth and some others. — [forever NamePlateDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/NamePlateDocumentation.lua), [forever UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Soft-target settings exist on Forever: there is a `SoftTargetEnableFlags` enum (None/Gamepad/Kbm/Any), and Blizzard's Forever nameplate code reads soft-target icon CVars and checks `UnitIsUnit(frame.displayedUnit, "softenemy")`. — [forever SoftTargetConstantsDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SoftTargetConstantsDocumentation.lua), [forever CompactUnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)
- Boss units on vanilla-content clients:
  - The `classic_era` branch tree has no boss-frame files at all (a path search for "boss" returned nothing). — [wow-ui-source classic_era tree](https://github.com/Gethe/wow-ui-source/tree/classic_era)
  - In the `forever` branch, the Camelot (Forever) unit-frame code mentions "boss" only in `GetBossPortraitFrameData` (`UnitIsBossMob`, used for portrait art). Only the shared Mainline `TargetFrame.lua` references boss frames. — [forever Blizzard_UnitFrame/Camelot/TargetFrameUtils.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Camelot/TargetFrameUtils.lua)
  - The Forever docs mention `boss1` only in secret-predicate example text.
- GUID secrecy:
  - Forever and retail `UnitGUID` entries carry `SecretWhenUnitIdentityRestricted = true`.
  - Forever predicate text: "Guarded APIs and events produce secret values when the unit isn't player-controlled or in the party/raid. For compound tokens (eg. 'boss1target'), results are secret if any unit in the chain fails this." — [forever SecretPredicatesDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicatesDocumentation.lua)
  - `UnitTokenFromGUID` and `UnitCreatureID` carry the same predicate. `UnitCreatureID` also has `RequiresUnitIdentityAccess`. — [forever UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
  - Classic Era `UnitGUID` has no secret annotation. — [classic_era UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Retail rule history for creature identity:
  - Alpha 6 (2025-10-27): "Access to creature unit names, GUIDs, and IDs are secret while in an instance (and are no longer affected by combat state)."
  - 2025-11-11: "UnitIsUnit no longer works when either unit is secret."
  - 2025-12-01: relaxed to give non-secret results for `target`, `focus`, `mouseover` and others, but "The result of UnitIsUnit will remain secret if the other unit token being compared against is a compound token."
  - Source: [Patch 12.0.0/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes)
  - 12.0.1 (2026-03-21): "The UnitCreatureID API now returns nil when unit identity is secret." — [Patch 12.0.1/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.1/API_changes/notes)
- `UnitIsUnit` on Forever and retail carries `RequiresComparableUnitTokens = true` and `SecretWhenUnitComparisonRestricted = true`:
  - Precondition text: "comparisons where either unit is 'player' or 'target' are permitted, but comparisons between 'nameplate3' and 'boss1' are not" (failure mode ReturnNothing).
  - Comparison secrecy: "Comparisons involving compound unit tokens (eg. 'boss1target') are always secret. This restriction only applies when the player is on an addon-restricted map."
  - `C_Secrets.CanCompareUnitTokens(unit1, unit2)` and `C_Secrets.ShouldUnitComparisonBeSecret(unit1, unit2)` let you test both conditions ahead of time.
  - Sources: [forever SecretPredicatesDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicatesDocumentation.lua), [forever SecretPredicateAPIDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicateAPIDocumentation.lua)
- Classic Era `UnitIsUnit` already has `RequiresComparableUnitTokens` but no secret predicate. — [classic_era UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Tainted code cannot use secret values as table keys and cannot compare or boolean-test them. It can store them and pass them to some native APIs, such as `StatusBar:SetValue`. `issecretvalue()` and `canaccessvalue()` test for secrecy. — [warcraft.wiki.gg Secret values](https://warcraft.wiki.gg/wiki/Secret_values)
- 12.0.0 Beta 6/7 (Jan 2026):
  - "GetNamePlateForUnit no longer accepts compound unit tokens (e.g. boss1target) from tainted code."
  - The new type `UnitTokenRestrictedForAddOns` "doesn't accept compound unit tokens (boss1target) or player/pet names from addons". "The 'targettarget' token is exempt from this restriction."
  - Source: [Patch 12.0.0/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes)
- 12.0.1 (2026-02-19): "Various APIs no longer accept compound unit tokens or unit names when in an active PvP match." — [Patch 12.0.1/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.1/API_changes/notes)

### Inferences
- Without nameplates, the most an addon can see is the union of:
  - `target`, `focus`, `mouseover` and `softenemy`;
  - each group member's target (`partyNtarget`, `raidNtarget`);
  - each pet's target (`pettarget`, `partypetNtarget`, `raidpetNtarget`);
  - `targettarget`/`focustarget` chains;
  - `bossN`, if the client populates it during an encounter.
- That union loses every mob that nobody is targeting. Examples: adds beating on a healer who targets a friendly, a second pull nobody has tabbed to, and mobs on a tank who is tab-cycling. In a 5-man group that is at most about 10–14 distinct reachable tokens.
- Bosses usually are targeted, so the loss is mainly multi-mob pulls, which is exactly where a tank threat display matters most.
- De-duplication:
  - Where creature GUIDs are readable (Classic Era always; Forever and retail outside restricted conditions), compare `UnitGUID` strings.
  - Where they are secret, `UnitGUID` returns can't be used as table keys or compared. Fall back to `UnitIsUnit`. `UnitIsUnit("nameplateN","target")` is allowed, but comparisons involving compound tokens (`party1target`) are secret on addon-restricted maps. So de-duplicating party-target tokens inside dungeons may be impossible on Forever if it treats dungeons as restricted maps.
  - Calling `C_Secrets.ShouldUnitIdentityBeSecret(unit)` and `C_Secrets.ShouldUnitComparisonBeSecret(u1,u2)` at runtime is the safe way to branch.
- `arenaN` and `npc` are irrelevant to PvE threat.

### Gaps
- Whether `boss1..5` is populated on Forever during vanilla raid encounters could not be confirmed from source. The Camelot UI has no boss frames, and no Forever doc ties boss tokens to vanilla encounters. Testing in-game is needed (`/dump UnitExists("boss1")` during an encounter).
- Whether Forever treats open world, dungeons or raids as "addon-restricted maps" (which drives comparison and identity secrecy) is not stated in the docs. It must be tested with `C_Secrets.ShouldUnitIdentityBeSecret("nameplate1")` and `C_Secrets.ShouldUnitComparisonBeSecret("party1target","target")` in each context.
- The wiki gives no per-flavor availability for `softenemy`. Forever clearly ships soft-target support, but whether it is enabled by default is unknown.

## 2. Threat API: what each function returns, what the events carry, and whether any API lists a threat table

### Takeaway
The threat API is strictly pairwise: you ask about one unit and one mob, and both must be unit tokens. There is no C_ThreatList or any function that returns a mob's threat table or the mobs a unit is on. `UnitThreatSituation(unit)` with no mob argument does aggregate across every mob the unit is on, without needing tokens for those mobs, and Blizzard's own raid-frame aggro highlight relies on this.

### Cited Findings
- `UnitThreatSituation(unit [, mobUnit])` returns:
  - nil: the unit is not on the mob's threat table (or not on any table, if `mobUnit` is omitted);
  - 0: below 100% and not the primary target;
  - 1: above 100% but not the primary target (yellow);
  - 2: primary target, but another unit is above 100% (orange);
  - 3: securely primary target (red).
  - With `mobUnit` omitted, the values "reflect whichever NPC unit the player unit has the highest threat against".
  - A pet attacking while its owner has done nothing returns no data.
  - Added to Classic in 1.13.5.
  - Source: [warcraft.wiki.gg API_UnitThreatSituation](https://warcraft.wiki.gg/wiki/API_UnitThreatSituation)
- Blizzard's own Forever code comment contradicts the wiki's "highest threat" wording: "Frames displaying raid or party members should be set up to get the max threat of the displayed unit on all units they're attacking." That comment sits above `return UnitThreatSituation(frame.displayedUnit);`. The function `GetAggroHighlightThreatSituation` returns nil if `UnitInParty("player") == false`. — [forever CompactUnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua). Note: the wiki says "highest threat" and Blizzard's comment says "max threat"; neither states plainly whether it is the max *status* across mobs.
- `UnitDetailedThreatSituation(unit, mobUnit)` returns:
  - `isTanking`: true if the unit is the mob's primary target;
  - `status`: 0–3 as above;
  - `scaledPercentage`: 100 means primary target; scaled by distance; always 100 or lower;
  - `rawPercentage`: relative to the current primary target; can exceed 100, up to 255; stops updating once the unit is the primary target;
  - `threatValue`/`rawThreat`: total threat; the wiki states no unit or scale factor.
  - Socially pulled mobs often report 0 instead of 3.
  - Since 4.0.3, temporary threat-drop effects report 0.
  - Source: [warcraft.wiki.gg API_UnitDetailedThreatSituation](https://warcraft.wiki.gg/wiki/API_UnitDetailedThreatSituation)
- Forever doc entry for `UnitDetailedThreatSituation`:
  - `MayReturnNothing = true`, `SecretWhenUnitThreatValuesRestricted = true`, `SecretArguments = "AllowedWhenUntainted"`.
  - Arguments: `unit` (UnitToken), `mobGUID` (Type UnitToken, despite its name).
  - Returns: `isTanking` bool, `status` number, `scaledPercentage`, `rawPercentage`, `rawThreat`.
  - Retail is the same. Classic Era has the same signature with no secret predicates.
  - Sources: [forever UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua), [live UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua), [classic_era UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Other Forever doc entries:
  - `UnitThreatSituation`: `SecretWhenUnitThreatStateRestricted = true`; args `unit`, `mobGUID` (UnitToken, Nilable = true); returns `result` number, nilable.
  - `UnitThreatPercentageOfLead(unit, mobGUID)`: `SecretWhenUnitThreatValuesRestricted`; returns a nilable number.
  - `UnitThreatLeadSituation(unit, mobGUID)`: `SecretWhenUnitThreatStateRestricted`. Doc text: "Returns a threat state (0-3; representing none, yellow, orange, red) that indicates how far the provided unit is above the secondmost threat on the provided mob. If the unit is not first on threat, will always return red. Can return nil if the provided mob does not exist." It exists on the forever, classic_era and live branches.
  - Source: [forever UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Forever's Blizzard nameplate threat colouring calls `UnitThreatSituation("player", nameplate)` for DPS and `UnitThreatLeadSituation("player", nameplate)` for tanks ("Show Tanks how close they are to losing threat to the second highest threat or red if they're not the highest threat"). — [forever CompactUnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua)
- The whole Forever `Threat` system (ThreatDocumentation.lua) contains only `GetThreatStatusColor(gameErrorIndex)` (returns r,g,b; `SecretArguments = "AllowedWhenUntainted"`) and `IsThreatWarningEnabled()`. It has no events and no list functions.
  - The Forever API doc folder has no C_ThreatList file. The only threat-related files are ThreatDocumentation.lua and the Unit/SecretPredicate docs.
  - Sources: [forever ThreatDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/ThreatDocumentation.lua), [forever Blizzard_APIDocumentationGenerated folder](https://github.com/Gethe/wow-ui-source/tree/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated)
- Events (Forever docs): `UNIT_THREAT_LIST_UPDATE` and `UNIT_THREAT_SITUATION_UPDATE` each carry one payload, `unitTarget` (UnitTokenVariant), and are tagged SynchronousEvent and UniqueEvent. — [forever UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- `UNIT_THREAT_LIST_UPDATE` fires when a mob's threat list changes, for `"target"` and `"nameplateX"` ("possibly other units").
  - It does not fire for `targettarget` or `raidXtarget` (noted as of 1.13.6), although `UnitDetailedThreatSituation` still returns updated values for those tokens.
  - The wiki adds: "Healer threat addons may need to poll UnitDetailedThreatSituation periodically", and enemies can be outside nameplate range, "which is very short in Classic".
  - Source: [warcraft.wiki.gg UNIT_THREAT_LIST_UPDATE](https://warcraft.wiki.gg/wiki/UNIT_THREAT_LIST_UPDATE)
- `UNIT_THREAT_SITUATION_UPDATE` is "Fired when an available unit on an available mob's threat list moves past another unit on that list". The wiki does not list which tokens it fires for. — [warcraft.wiki.gg UNIT_THREAT_SITUATION_UPDATE](https://warcraft.wiki.gg/wiki/UNIT_THREAT_SITUATION_UPDATE)
- Blizzard's Forever party/raid frames register `UNIT_THREAT_SITUATION_UPDATE` per *friendly* unit, using `RegisterUnitEvent(..., unit, displayedUnit)`. The unit-frame threat indicator handles it for its `feedbackUnit`, which is a friendly unit. So for this event the unit argument is the friendly unit whose situation changed, not the mob. — [forever CompactUnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.lua), [forever Mainline UnitFrame.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UnitFrame/Mainline/UnitFrame.lua)

### Inferences
- `UnitThreatSituation("player")` with no mob argument can tell you that something is on you, without any enemy token:
  - non-nil means you are on at least one threat table;
  - 3 or 2 means you are some mob's primary target, according to Blizzard's "max threat across all units they're attacking" usage.
- The same works for `UnitThreatSituation("partyN")`/`("raidN")`/`("pet")`. That is how Blizzard's raid-frame aggro glow works with no enemy enumeration.
- Under the Forever predicate wording, single-token queries are "generally not secret", so this should stay readable in combat. That matches the user's observation that the status is readable.
- What it cannot tell you: which mob, how many mobs, or per-mob numbers. And because it reports the highest-threat mob, a tank holding mob A who has lost mob B may still read 3.
- `UNIT_THREAT_SITUATION_UPDATE` with a friendly unit argument fires because some mob's ordering changed. It plausibly fires for mobs without tokens, since its unit is the friendly unit, but no source confirms this (see Gaps).
- `UNIT_THREAT_LIST_UPDATE` is keyed by the mob token, so it only fires for mobs that have a token (target, nameplate). Mobs without a token give no event, and polling is impossible without a token anyway.

### Gaps
- Whether `UNIT_THREAT_SITUATION_UPDATE` fires for a friendly unit when the mob involved has no nameplate or target token is not documented. Needs an in-game test.
- The exact semantics of the no-mob form (max status vs. status on the highest-raw-threat mob) are not authoritatively documented. The wiki and Blizzard's code comment word it differently.
- Unit and scale of `rawThreat` (historically threat × 100) are not stated on the current wiki page. Not verified.

## 3. Midnight (12.x) secret values for threat and identity, and how threat addons adapted

### Takeaway
Retail 12.x applies the same annotations Forever has: `SecretWhenUnitThreatStateRestricted` on the status functions and `SecretWhenUnitThreatValuesRestricted` on the numeric functions. Secrecy depends on the pair of tokens passed in. Blizzard shipped a built-in damage meter, not a threat meter. Threat addons (Threat Plates, MidnightThreat) kept working mostly through readable status values and token pairs that involve the player, and dropped features that compare units (off-tank detection).

### Cited Findings
- The Forever predicates and their wording (retail `live` has the same predicate names):
  - `SecretWhenUnitThreatStateRestricted`: "Queries where only one unit token is specified, or where one unit token is the player, their pet, or an ally while the other is a nameplate, boss, target, etc., are generally not secret."
  - `SecretWhenUnitThreatValuesRestricted`: "Queries where only one unit token is specified, or where one unit token is the player, their pet, or an ally while the other is a non-boss or nameplate target, are generally not secret."
  - Sources: [forever SecretPredicatesDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicatesDocumentation.lua), [live SecretPredicatesDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicatesDocumentation.lua)
- C_Secrets threat functions (Forever; retail is the same):
  - `C_Secrets.ShouldUnitThreatStateBeSecret(unit, mobUnit?)` → bool. Doc: "Returns true if queries for unit threat status will produce secret values."
  - `C_Secrets.ShouldUnitThreatValuesBeSecret(unit, mobUnit)` → bool (mobUnit not nilable). Doc: "...unit threat values will produce secret values."
  - `C_Secrets.ShouldUnitIdentityBeSecret(unit)`: "...unit identity (such as name or GUID) will produce secret values."
  - `C_Secrets.HasSecretRestrictions()`: "Returns true if this client build has secret value restrictions enabled. If false, all APIs that are tagged as potentially returning secrets will never do so."
  - The Classic Era branch has the same C_Secrets list, missing only `ShouldSpellBookItemCooldownBeSecret`. So the predicate API exists on Classic Era too, even though its Unit functions carry no secret annotations.
  - Sources: [forever SecretPredicateAPIDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicateAPIDocumentation.lua), [classic_era SecretPredicateAPIDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/classic_era/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicateAPIDocumentation.lua)
- Retail 12.0.1 (2026-02-19): "Threat APIs now conditionally return secrets for some combinations of input unit tokens to prevent unintended use of these functions to compare units." — [Patch 12.0.1/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.1/API_changes/notes)
- The wiki's C_Secrets.ShouldUnitThreatStateBeSecret page links its retail version to the Patch 12.0.1 API changes page, which suggests it was added in 12.0.1; the page doesn't say so outright. It lists the function for forever 1.60.1, mists 5.5.4, tbc 2.5.6 and vanilla 1.15.9. — [warcraft.wiki.gg API_C_Secrets.ShouldUnitThreatStateBeSecret](https://warcraft.wiki.gg/wiki/API_C_Secrets.ShouldUnitThreatStateBeSecret)
- Retail 12.0.0:
  - The combat log was removed for addons: "Combat Log Events are no longer available to addons" (2025-10-01).
  - Aura access was "secret while in combat" (2025-10-11).
  - Creature names, GUIDs and IDs are secret in instances, independent of combat (2025-10-27).
  - The goals of the changes include preventing "colorizing unit nameplates based on priority" (2025-11-13).
  - Source: [Patch 12.0.0/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes)
- 12.0.5 added the predicate `SecretOnRestrictedMaps` ("when the player is on an addon-restricted map such as a dungeon or raid"). The wiki says the cvar `addonEncounterRestrictionsForced` and similar cvars simulate restriction states. — [warcraft.wiki.gg Secret values](https://warcraft.wiki.gg/wiki/Secret_values)
- Blizzard's official philosophy post (Midnight, 2025):
  - Addons stay "robust tools for aesthetic customization and personalized presentation of information".
  - Nameplate addons "can change the size and shape and texture of enemy nameplates and cast bars".
  - Combat information may be displayed by addons but not "known" by them.
  - Blizzard is adding "a built-in Damage Meters tool with server-side validation".
  - The post does not mention threat meters.
  - Source: [Blizzard news: Combat Philosophy and Addon Disarmament in Midnight](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight)
- The built-in damage meter shipped in the base UI, off by default; Blizzard Watch ran a how-to on 2026-01-21. I found no source for a built-in threat meter. One secondary report says enemy nameplates got "improved threat indicators". — [Blizzard: Midnight UI updates](https://news.blizzard.com/en-us/article/24223311/midnight-get-up-to-speed-with-user-interface-updates), [Blizzard Watch 2026-01-21](https://blizzardwatch.com/2026/01/21/activate-use-new-built-damage-meter-wow-midnight)
- 12.0.0 (Dec 2025) Damage Meter API changes aimed "to allow addons to be able to access certain information as non-secrets". "The name field in DamageMeterCombatSource is now only secret for units whose identities are secret." — [Patch 12.0.0/API changes/notes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes)
- Threat Plates 13.0.0-beta20 (2026-02-27):
  - "Disabled off-tank detection as UnitIsUnit returns secret values"
  - "Disabled cast target in instances as UnitName returns secret values"
  - "Fixed a root cause for lots of Lua errors caused by secret values"
  - Source: [CurseForge Threat Plates file 7687607](https://www.curseforge.com/wow/addons/tidy-plates-threat-plates/files/7687607)
- MidnightThreat, a new Midnight threat meter:
  - It aims to "display the information made available by the game client without bypassing Blizzard's restrictions".
  - "some threat information and warnings may be limited or unavailable during combat".
  - It shows group threat with a tank marker.
  - The page does not say how it enumerates mobs.
  - Source: [CurseForge MidnightThreat](https://www.curseforge.com/wow/addons/midnightthreat)
- Plater's release notes mention a "Unit type coloring option to not override threat colors" and "More support for Midnight (work in progress...)". They give no technical threat details. — [CurseForge Plater file 7497201](https://www.curseforge.com/wow/addons/plater-nameplates/files/7497201)
- Omen relies "completely on the Blizzard threat API and threat events". I found no Midnight-specific Omen changelog. — [WowAce Omen](https://www.wowace.com/projects/omen-threat-meter)

### Inferences
- The predicate wording implies the design intent:
  - Self-vs-mob or ally-vs-mob status stays readable, which is enough for "am I tanking it" colouring.
  - Pairs that would let an addon infer who a mob is targeting, or compare boss units to other tokens, go secret.
  - Numeric values for boss tokens are singled out as secret ("non-boss or nameplate target").
- On Forever, the user observes numeric threat values are secret (`ShouldUnitThreatValuesBeSecret` true) even for player vs nameplate. That is stricter than the predicate text's "generally not secret". Forever presumably runs with combat restrictions active more broadly (e.g. "SecretWhenInCombat"-style gating), so the doc text should not be trusted over runtime checks.
- Midnight addons converged on these patterns:
  - pass secret numbers straight to StatusBars (display, not know);
  - colour from readable `status`;
  - drop features that need unit comparison.
- No evidence was found that any retail threat addon enumerates mobs without nameplates in Midnight.

### Gaps
- No public changelog from ThreatClassic2, Omen or Details (Tiny Threat) describing a Midnight adaptation was found.
- No Blizzard blue post about threat meters in Midnight was found.
- The exact runtime conditions under which retail's threat values go secret (combat? instance? token pair only?) aren't spelled out beyond the predicate text.

## 4. Exact Forever doc entries and the limits of nameplate scanning

### Takeaway
On Forever, `C_NamePlate.GetNamePlates()` and `GetNamePlateForUnit()` are unrestricted, with no secret predicates. Nameplate scanning itself is limited:
- `nameplate1..40`: at most 40 plates;
- enemy nameplates must be enabled;
- `nameplateMaxDistance`: historically 20 yards on Classic, community-reported 41 maximum;
- forbidden plates can't be touched by addons.

It is still the only way to see untargeted mobs.

### Cited Findings
- Forever `C_NamePlate` (System "NamePlate"):
  - `GetNamePlateForUnit(unitToken: UnitTokenNamePlate, includeForbidden: bool = false)` → `nameplate` NamePlateFrame. `SecretArguments = "AllowedWhenUntainted"`.
  - `GetNamePlates()` → table of NamePlateFrame. No predicates.
  - `GetNamePlateSize()`.
  - `SetNamePlateSize(width, height)`: `HasRestrictions = true`.
  - The live branch has an identical file size.
  - Source: [forever NamePlateDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/NamePlateDocumentation.lua)
- Forever `C_NamePlateManager`:
  - `IsNamePlateUnitBehindCamera(unitToken)`.
  - `SetNamePlateSimplified(unitToken, bool)`.
  - `Get/SetNamePlateHitTestInsets`. Set has `HasRestrictions` and `SecretArguments = "NotAllowed"`. Doc: "all hit testing is clamped to the bounds of the nameplate".
  - Events: `NAME_PLATE_CREATED`, `NAME_PLATE_UNIT_ADDED(unitToken)`, `NAME_PLATE_UNIT_REMOVED(unitToken)`, `FORBIDDEN_NAME_PLATE_CREATED/UNIT_ADDED/UNIT_REMOVED`, `NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED(unitTarget, isBehindCamera)`.
  - Source: [forever NamePlateManagerDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/NamePlateManagerDocumentation.lua)
- Forever threat-function annotations are listed under section 2. Other relevant Forever entries:
  - `UnitAffectingCombat`, `UnitCanAttack`, `UnitIsEnemy`, `UnitReaction`, `UnitExists`, `UnitIsDead`, `UnitIsTapDenied`, `UnitClassification` and `UnitIsBossMob` have only `SecretArguments = "AllowedWhenUntainted"`, with no secret predicate. They stay readable for filtering.
  - `UnitHealth` has `SecretReturns = true`.
  - `UnitInRange` has `SecretReturns = true`.
  - `UnitName` has `SecretWhenUnitNameIdentityRestricted`.
  - Source: [forever UnitDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- Other Forever predicates (text in SecretPredicatesDocumentation.lua):
  - `SecretWhenInCombat`: "when combat addon restrictions are in effect".
  - `SecretOnRestrictedMaps`: dungeon or raid.
  - `RequiresUnitIdentityAccess`: "protected APIs will return no values".
  - Source: [forever SecretPredicatesDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/SecretPredicatesDocumentation.lua)
- Nameplate token cap: `nameplateN` covers 1–40. — [warcraft.wiki.gg UnitId](https://warcraft.wiki.gg/wiki/UnitId)
- Nameplate distance on Classic:
  - Wowhead reported the Classic max as 20 yards for all nameplates, later hotfixed. Scientific-notation values were once accepted, "upper limit because of render distance". — [Wowhead Classic news](https://pt.classic.wowhead.com/news/blizzard-hotfixed-command-to-increase-nameplate-range-in-classic-wow-295078)
  - TBC Classic raised it to a 0–41 yard range. — [Wowhead: increased nameplate distance in BCC](https://www.wowhead.com/news=322306/increased-nameplate-distance-coming-in-burning-crusade-classic)
  - Forum users report `/run SetCVar("nameplateMaxDistance", 41)` on Era/Anniversary, but some say it reverts to 20. — [Blizzard forums: WoW Classic Anniversary nameplate distance](https://eu.forums.blizzard.com/en/wow/t/wow-classic-anniversary-nameplate-distance/554190), [Blizzard forums: Nameplate range](https://us.forums.blizzard.com/en/wow/t/nameplate-range/1666121)
- Blizzard's Forever nameplate driver reads the `nameplateShowAll`, `nameplateShowPersonal` and class-colour CVars (`GetCVarBool("nameplateShowClassColor")`), and the soft-target icon CVars. — [forever Blizzard_NamePlates.lua](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlates.lua)

### Inferences
- Nameplate scanning is necessary to see mobs nobody targets, and it is the only token family that reaches them.
- It is not necessary to detect "something is on me / on a group member": `UnitThreatSituation(friendlyUnit)` with no mob covers that.
- A hybrid design is possible:
  - enumerate nameplates plus target/focus/mouseover/softenemy plus group targets;
  - de-duplicate with `UnitIsUnit` against `target` (allowed);
  - use `UnitThreatSituation("player")` as a catch-all alarm for mobs outside nameplate range or with plates disabled.
- Practical scanning limits:
  - nameplates must be enabled for enemies (`nameplateShowEnemies`);
  - `nameplateShowAll` affects whether plates show outside combat;
  - range is capped by `nameplateMaxDistance` (likely 20–41 yards on a vanilla-content client);
  - at most 40 plates;
  - forbidden plates are untouchable (`includeForbidden` exists, but addons can't use those frames).
- Enemies behind the camera still have plates. `IsNamePlateUnitBehindCamera` exists to detect that.

### Gaps
- Forever's actual default and maximum for `nameplateMaxDistance` were not found in source or online.
- I found no source on whether nameplates are culled by line of sight. Historically they are distance-based, not LOS-based, with an occlusion alpha CVar, but that is unverified here.
- The `nameplateShowEnemies` default on Forever was not verified.
- Whether `UnitDetailedThreatSituation` on Forever returns secrets for *all* token pairs in combat, or only some, needs a runtime check of `C_Secrets.ShouldUnitThreatValuesBeSecret("player","nameplate1")` vs `("player","target")` in and out of combat and instances.
