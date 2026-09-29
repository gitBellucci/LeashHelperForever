--[[
  Leash Helper for WoW Classic Forever

  Classic leash is a ~11–15s chase timer from last hostile action. Linked
  packs share that timer: striking any one of them refreshes all of them.
  DoT ticks do not refresh the leash; only a real hit or aggro does.

  Forever runs Midnight-style secret values: unit names, GUIDs and UnitIsUnit
  comparisons can be unreadable (always in dungeons). Secret values can still
  be handed to widget APIs, so names are displayed with SetText but never
  compared. Identity comes from, in order: readable GUID, nameplate token
  (unique while the plate is shown), then a public unit token (target, focus,
  pettarget, partyNtarget) until that token changes.
]]

local ADDON_NAME = ...

local LH = {}
_G.LeashHelper = LH

local VERSION = "1.0.12"

local format = string.format
local wipe = wipe or table.wipe
local GetTime = GetTime
local IsInRaid = IsInRaid
local IsInGroup = IsInGroup
local GetNumGroupMembers = GetNumGroupMembers

local defaults = {
	enabled = true,
	disableInDungeons = true,
	locked = false,
	preview = false,
	debug = false,
	showPortraits = true,
	showNames = true,
	point = "CENTER",
	x = 0,
	y = 180,
	width = 260,
	font = "Fonts\\FRIZQT__.TTF",
	fontSize = 18,
	nameSize = 12,
	iconSize = 28,
}

-- Seconds a row may sit at 0.0 before it is removed.
local EXPIRE_GRACE = 0.4
-- Mob combat flag must stay off this long before its row is removed.
local OOC_GRACE = 0.5
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local TEST_ICON = "Interface\\Icons\\Ability_Warrior_Charge"

local debugLines = {}
local lastTickErr
local DEBUG_MAX = 160

local db
local mobs = {}
local inCombat = false
local testUntil = 0
local nextId = 0
local window, ticker
local rows = {}
local lastSpellCastAt = 0

---------------------------------------------------------------------------
-- Secret-safe primitives
---------------------------------------------------------------------------

local function IsSecret(v)
	if issecretvalue then
		return issecretvalue(v) and true or false
	end
	return false
end

-- true / false / nil (call failed or the answer is secret).
local function Bool(fn, ...)
	if not fn then
		return nil
	end
	local ok, v = pcall(fn, ...)
	if not ok or IsSecret(v) then
		return nil
	end
	return v and true or false
end

local function Num(fn, ...)
	if not fn then
		return nil
	end
	local ok, v = pcall(fn, ...)
	if not ok or IsSecret(v) or type(v) ~= "number" then
		return nil
	end
	return v
end

local function SafeNum(v)
	if IsSecret(v) or type(v) ~= "number" then
		return nil
	end
	return v
end

local function SafeStr(v)
	if IsSecret(v) or type(v) ~= "string" then
		return nil
	end
	return v
end

local function Printable(v)
	if IsSecret(v) then
		return "<secret>"
	end
	return tostring(v)
end

local function Flag(v)
	if v == nil then
		return "?"
	end
	return v and "y" or "n"
end

local function Dbg(fmt, ...)
	if not db or not db.debug then
		return
	end
	local msg = fmt
	if select("#", ...) > 0 then
		local ok, built = pcall(format, fmt, ...)
		if ok and not IsSecret(built) then
			msg = built
		end
	end
	debugLines[#debugLines + 1] = format("%.1f  %s", GetTime(), tostring(msg))
	while #debugLines > DEBUG_MAX do
		table.remove(debugLines, 1)
	end
	if LH.RefreshDebug then
		LH.RefreshDebug()
	end
end

local function SecretsOn()
	return C_Secrets and C_Secrets.HasSecretRestrictions and Bool(C_Secrets.HasSecretRestrictions) == true
end

local function ReadableGUID(unit)
	if not unit or not UnitGUID then
		return nil
	end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok then
		return nil
	end
	return SafeStr(guid)
end

---------------------------------------------------------------------------
-- Unit tokens
---------------------------------------------------------------------------

local function IsNameplateToken(unit)
	return type(unit) == "string" and unit:find("^nameplate%d+$") ~= nil
end

local function IsGroupToken(unit)
	if unit == "player" or unit == "pet" or unit == "vehicle" then
		return true
	end
	if type(unit) ~= "string" then
		return false
	end
	return unit:find("^party%d+$") ~= nil or unit:find("^partypet%d+$") ~= nil
		or unit:find("^raid%d+$") ~= nil or unit:find("^raidpet%d+$") ~= nil
end

local function IsPartyTargetToken(unit)
	return type(unit) == "string" and (unit:find("^party%d+target$") ~= nil or unit:find("^raid%d+target$") ~= nil)
end

-- Tokens with a reliable "changed" event, so they can identify a mob until then.
local function IsBindableToken(unit)
	return unit == "target" or unit == "focus" or unit == "pettarget" or IsPartyTargetToken(unit)
end

local function ForEachGroupUnit(fn)
	if fn("player") or fn("pet") then
		return true
	end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			if fn("raid" .. i) or fn("raidpet" .. i) then
				return true
			end
		end
	elseif IsInGroup() then
		for i = 1, math.max(GetNumGroupMembers() - 1, 0) do
			if fn("party" .. i) or fn("partypet" .. i) then
				return true
			end
		end
	end
	return false
end

local function PartyTargetTokens()
	local list = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			list[#list + 1] = "raid" .. i .. "target"
		end
	elseif IsInGroup() then
		for i = 1, math.max(GetNumGroupMembers() - 1, 0) do
			list[#list + 1] = "party" .. i .. "target"
		end
	end
	return list
end

local function PlateFrame(unit)
	if not unit or not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then
		return nil
	end
	local ok, frame = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	if not ok or not frame or IsSecret(frame) then
		return nil
	end
	return frame
end

local function FindPlateToken(unit)
	local frame = PlateFrame(unit)
	if frame then
		local ok, token = pcall(function()
			return frame.namePlateUnitToken or (frame.UnitFrame and frame.UnitFrame.unit)
		end)
		token = ok and SafeStr(token) or nil
		if token and IsNameplateToken(token) and PlateFrame(token) == frame then
			return token
		end
		-- The plate frame is a plain table even when names/GUIDs are secret,
		-- so frame identity links "target" to its nameplate token.
		for i = 1, 40 do
			local plate = "nameplate" .. i
			if PlateFrame(plate) == frame then
				return plate
			end
		end
	end
	for i = 1, 40 do
		local plate = "nameplate" .. i
		if Bool(UnitExists, plate) == true and Bool(UnitIsUnit, unit, plate) == true then
			return plate
		end
	end
	return nil
end

local plateCache = {}
local plateCacheAt = -1

local function ResetPlateCache()
	wipe(plateCache)
end

-- Nameplate token currently showing this unit. Works without UnitIsUnit,
-- which is secret in dungeons.
local function PlateTokenOf(unit)
	if IsNameplateToken(unit) then
		return unit
	end
	if not unit then
		return nil
	end
	local now = GetTime()
	if plateCacheAt ~= now then
		wipe(plateCache)
		plateCacheAt = now
	end
	local cached = plateCache[unit]
	if cached == nil then
		cached = FindPlateToken(unit) or false
		plateCache[unit] = cached
	end
	return cached or nil
end

local function InInstance()
	if not IsInInstance then
		return false, nil
	end
	local ok, inInstance, instanceType = pcall(IsInInstance)
	if not ok or IsSecret(inInstance) then
		return false, nil
	end
	return inInstance and true or false, SafeStr(instanceType)
end

local function InDungeon()
	local _, instanceType = InInstance()
	return instanceType == "party"
end

local function AddonActive()
	if not db or not db.enabled then
		return false
	end
	if db.disableInDungeons and InDungeon() then
		return false
	end
	return true
end

local function PlayerInCombat()
	return inCombat or Bool(UnitAffectingCombat, "player") == true
end

---------------------------------------------------------------------------
-- Classification
---------------------------------------------------------------------------

-- Only hostile world NPCs. Anything we cannot prove is an NPC is rejected:
-- a missed mob is better than your own portrait on the bar.
local function IsTrackableNPC(unit)
	if type(unit) ~= "string" or IsGroupToken(unit) then
		return false
	end
	if Bool(UnitExists, unit) == false then
		return false
	end
	if Bool(UnitIsDeadOrGhost or UnitIsDead, unit) == true then
		return false
	end
	local isPlayer = Bool(UnitIsPlayer, unit)
	local controlled = Bool(UnitPlayerControlled, unit)
	if isPlayer == true or controlled == true then
		return false
	end
	if isPlayer == nil and controlled == nil then
		return false
	end
	if UnitIsOtherPlayersPet and Bool(UnitIsOtherPlayersPet, unit) == true then
		return false
	end
	local guid = ReadableGUID(unit)
	if guid and not (guid:find("^Creature%-") or guid:find("^Vehicle%-")) then
		return false
	end
	if Bool(UnitIsUnit, unit, "player") == true or Bool(UnitIsUnit, unit, "pet") == true then
		return false
	end
	local attackable = Bool(UnitCanAttack, "player", unit)
	if attackable == nil then
		return Bool(UnitIsFriend, "player", unit) == false
	end
	return attackable
end

-- true / false / nil when comparisons are secret.
local function TargetingGroup(unit)
	if type(unit) ~= "string" then
		return false
	end
	local tt = unit .. "target"
	if Bool(UnitExists, tt) == false then
		return false
	end
	local unknown = false
	local hit = ForEachGroupUnit(function(g)
		local v = Bool(UnitIsUnit, tt, g)
		if v == nil then
			unknown = true
		end
		return v == true
	end)
	if hit then
		return true
	end
	if unknown then
		return nil
	end
	return false
end

local function OnGroupThreatTable(unit)
	if not UnitThreatSituation then
		return false
	end
	return ForEachGroupUnit(function(g)
		if Bool(UnitExists, g) == false then
			return false
		end
		local ok, s = pcall(UnitThreatSituation, g, unit)
		return ok and not IsSecret(s) and s ~= nil
	end)
end

local function IsOurFightToken(unit)
	if unit == "target" or unit == "focus" or unit == "pettarget" or IsPartyTargetToken(unit) then
		return true
	end
	if not IsNameplateToken(unit) then
		return false
	end
	if PlateTokenOf("target") == unit or PlateTokenOf("pettarget") == unit or PlateTokenOf("focus") == unit then
		return true
	end
	local tokens = PartyTargetTokens()
	for i = 1, #tokens do
		if PlateTokenOf(tokens[i]) == unit then
			return true
		end
	end
	return false
end

-- Is this mob fighting us or our group (not some stranger's mob nearby)?
local function Engaged(unit)
	if OnGroupThreatTable(unit) then
		return true
	end
	if TargetingGroup(unit) == true then
		return true
	end
	if Bool(UnitAffectingCombat, unit) ~= true or not PlayerInCombat() then
		return false
	end
	if IsOurFightToken(unit) then
		return true
	end
	-- Inside instances every in-combat mob near you is your group's fight,
	-- and identity checks there are secret.
	local inInstance = InInstance()
	return inInstance
end

---------------------------------------------------------------------------
-- Leash durations and crowd control
---------------------------------------------------------------------------

function LH.DurationForLevel(level)
	level = tonumber(level)
	if not level or level < 1 then
		return 15
	end
	if level <= 29 then
		return 11
	elseif level <= 39 then
		return 12
	elseif level <= 44 then
		return 13
	elseif level <= 49 then
		return 14
	end
	return 15
end

local CC_IDS = {
	[118] = true, [12824] = true, [12825] = true, [12826] = true, [28271] = true, [28272] = true,
	[8122] = true, [8124] = true, [10888] = true, [10890] = true,
	[9484] = true, [9485] = true, [10955] = true,
	[5782] = true, [6213] = true, [6215] = true, [5484] = true, [17928] = true,
	[710] = true, [18647] = true, [6789] = true, [17925] = true, [17926] = true,
	[2094] = true, [6770] = true, [2070] = true, [11297] = true,
	[1776] = true, [1777] = true, [8629] = true, [11285] = true, [11286] = true,
	[1833] = true, [408] = true, [8643] = true,
	[3355] = true, [14308] = true, [14309] = true, [19503] = true,
	[19386] = true, [24132] = true, [24133] = true,
	[2637] = true, [18657] = true, [18658] = true,
	[5211] = true, [6798] = true, [8983] = true,
	[853] = true, [5588] = true, [5589] = true, [10308] = true, [20066] = true,
	[5246] = true, [7922] = true, [12809] = true,
	[20549] = true, -- War Stomp
	[28730] = true, -- Arcane Torrent (silence, skip)
}

local CC_NAMES = {
	["Polymorph"] = true,
	["Fear"] = true,
	["Howl of Terror"] = true,
	["Psychic Scream"] = true,
	["Sap"] = true,
	["Gouge"] = true,
	["Blind"] = true,
	["Hibernate"] = true,
	["Freezing Trap Effect"] = true,
	["Scatter Shot"] = true,
	["Wyvern Sting"] = true,
	["Hammer of Justice"] = true,
	["Repentance"] = true,
	["Intimidating Shout"] = true,
	["Cheap Shot"] = true,
	["Kidney Shot"] = true,
	["Bash"] = true,
	["Shackle Undead"] = true,
	["Banish"] = true,
	["Death Coil"] = true,
	["War Stomp"] = true,
	["Concussion Blow"] = true,
}

local function AuraIsCC(unit)
	if not unit then
		return false
	end
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
			if not ok or not data or IsSecret(data) then
				break
			end
			local id = SafeNum(data.spellId)
			local name = SafeStr(data.name)
			if (id and CC_IDS[id]) or (name and CC_NAMES[name]) then
				return true
			end
		end
		return false
	end
	if UnitDebuff then
		for i = 1, 40 do
			local ok, name, _, _, _, _, _, _, _, _, spellId = pcall(UnitDebuff, unit, i)
			if not ok or not name then
				break
			end
			name = SafeStr(name)
			spellId = SafeNum(spellId)
			if (spellId and CC_IDS[spellId]) or (name and CC_NAMES[name]) then
				return true
			end
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------

local function LiveToken(rec)
	return rec.plate or rec.unit
end

local function DropKey(key, why)
	if not key or not mobs[key] then
		return
	end
	Dbg("drop %s (%s)", tostring(key), tostring(why))
	mobs[key] = nil
end

local function ClearAll()
	for key in pairs(mobs) do
		if key ~= "test" then
			mobs[key] = nil
		end
	end
end

local function FindRecord(guid, plate, unit)
	if guid then
		for _, rec in pairs(mobs) do
			if rec.guid == guid then
				return rec
			end
		end
	end
	if plate then
		for _, rec in pairs(mobs) do
			if rec.plate == plate then
				if guid and rec.guid and rec.guid ~= guid then
					rec.plate = nil
				else
					return rec
				end
			end
		end
		for _, rec in pairs(mobs) do
			if rec.unit and not rec.plate and PlateTokenOf(rec.unit) == plate
				and not (guid and rec.guid and rec.guid ~= guid) then
				return rec
			end
		end
	end
	if unit then
		for _, rec in pairs(mobs) do
			if rec.unit == unit then
				if guid and rec.guid and rec.guid ~= guid then
					rec.unit = nil
				else
					return rec
				end
			end
		end
	end
	return nil
end

local function FindForUnit(unit)
	return FindRecord(ReadableGUID(unit), PlateTokenOf(unit), IsBindableToken(unit) and unit or nil)
end

-- Another row pointing at the same unit is the same mob: fold it in.
local function Absorb(rec, other)
	if other.expires and (not rec.expires or other.expires > rec.expires) then
		rec.expires = other.expires
	end
	rec.seenInCombat = rec.seenInCombat or other.seenInCombat
	if not rec.hasName and other.hasName then
		rec.name, rec.hasName = other.name, true
	end
	DropKey(other.key, "merged")
end

local function Bind(rec, guid, plate, unit)
	if guid then
		rec.guid = guid
	end
	for key, other in pairs(mobs) do
		if other ~= rec and key ~= "test" then
			if guid and other.guid == guid then
				Absorb(rec, other)
			else
				local sameGuidOrUnknown = not (guid and other.guid and other.guid ~= guid)
				if plate and other.plate == plate then
					if sameGuidOrUnknown then
						Absorb(rec, other)
					else
						other.plate = nil
					end
				elseif unit and other.unit == unit then
					if sameGuidOrUnknown then
						Absorb(rec, other)
					else
						other.unit = nil
					end
				end
			end
		end
	end
	local before = LiveToken(rec)
	if plate then
		rec.plate = plate
	end
	if unit then
		rec.unit = unit
	end
	if LiveToken(rec) ~= before then
		rec.portraitDirty = true
	end
end

local function UpdateIdentity(rec, unit)
	local ok, name = pcall(UnitName, unit)
	if ok and name ~= nil then
		if IsSecret(name) then
			rec.name, rec.hasName = name, true
		elseif type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
			rec.name, rec.hasName = name, true
		end
	end
	local level = Num(UnitLevel, unit)
	if level then
		rec.duration = LH.DurationForLevel(level)
	elseif not rec.duration then
		rec.duration = LH.DurationForLevel(Num(UnitLevel, "player"))
	end
end

local function StartTimer(rec, now, token)
	local dur = rec.duration or 15
	if token and AuraIsCC(token) then
		rec.paused = true
		rec.pauseLeft = dur
	else
		rec.paused = false
		rec.pauseLeft = nil
		rec.expires = now + dur
	end
	rec.lastHit = now
	rec.zeroSince = nil
	rec.oocSince = nil
end

-- Classic linked packs: a hit on one refreshes every mob still fighting you.
-- Rows we can no longer see are not refreshed, so a missed death still expires.
-- A mob that is evading home has dropped its target and is not refreshed.
local function RefreshPack(except, now)
	for key, rec in pairs(mobs) do
		if key ~= "test" and rec ~= except then
			local token = LiveToken(rec)
			if token and Bool(UnitIsDead, token) ~= true and Bool(UnitAffectingCombat, token) == true
				and TargetingGroup(token) ~= false then
				StartTimer(rec, now, token)
				rec.reason = "pack"
			end
		end
	end
end

local PACK_REASONS = {
	combat = true,
	aggro = true,
	["group-hit"] = true,
	cleu = true,
}

function LH.ResetLeash(unit, reason, knownEngaged)
	if not AddonActive() then
		return false
	end
	if not IsTrackableNPC(unit) then
		return false
	end
	local guid = ReadableGUID(unit)
	local plate = PlateTokenOf(unit)
	local bindUnit = IsBindableToken(unit) and unit or nil
	local rec = FindRecord(guid, plate, bindUnit)
	local now = GetTime()
	if not rec then
		if not knownEngaged and not Engaged(unit) then
			Dbg("ignore %s on %s: not our fight", tostring(reason), tostring(unit))
			return false
		end
		nextId = nextId + 1
		rec = { key = "m" .. nextId }
		mobs[rec.key] = rec
		Dbg("new %s from %s (%s) guid=%s plate=%s", rec.key, tostring(unit), tostring(reason), guid and "yes" or "hidden", tostring(plate))
	end
	Bind(rec, guid, plate, bindUnit)
	UpdateIdentity(rec, unit)
	StartTimer(rec, now, unit)
	rec.reason = reason
	if Bool(UnitAffectingCombat, unit) == true then
		rec.seenInCombat = true
	end
	if PACK_REASONS[reason] then
		RefreshPack(rec, now)
	end
	return true
end

-- Attach a token to an existing row without touching its timer.
local function BindExisting(unit)
	if not unit or not next(mobs) then
		return
	end
	if Bool(UnitIsDead, unit) == true then
		local rec = FindForUnit(unit)
		if rec then
			DropKey(rec.key, "dead")
		end
		return
	end
	if not IsTrackableNPC(unit) then
		return
	end
	local guid = ReadableGUID(unit)
	local plate = PlateTokenOf(unit)
	local bindUnit = IsBindableToken(unit) and unit or nil
	local rec = FindRecord(guid, plate, nil)
	if rec then
		Bind(rec, guid, plate, bindUnit)
		UpdateIdentity(rec, unit)
	end
end

local function UnbindToken(token)
	for _, rec in pairs(mobs) do
		if rec.unit == token then
			rec.unit = nil
		end
		if rec.plate == token then
			rec.plate = nil
		end
	end
end

local function DropByGuid(guid)
	for key, rec in pairs(mobs) do
		if key ~= "test" and rec.guid == guid then
			DropKey(key, "died")
		end
	end
end

local function PauseIfCC()
	local now = GetTime()
	for key, rec in pairs(mobs) do
		if key ~= "test" then
			local token = LiveToken(rec)
			local cc = token and AuraIsCC(token) or false
			if cc and not rec.paused then
				rec.pauseLeft = math.max((rec.expires or now) - now, 0)
				rec.paused = true
			elseif rec.paused and not cc then
				rec.expires = now + (rec.pauseLeft or rec.duration or 15)
				rec.paused = false
				rec.pauseLeft = nil
			end
		end
	end
end

-- A row known only as "target" and a row known by nameplate can be the same
-- mob when GUIDs are hidden. Fold them into one.
local function MergeDuplicates()
	for key, rec in pairs(mobs) do
		if key ~= "test" and mobs[key] == rec and rec.unit and not rec.plate then
			local plate = PlateTokenOf(rec.unit)
			if plate then
				local owner
				for _, other in pairs(mobs) do
					if other ~= rec and other.plate == plate then
						owner = other
						break
					end
				end
				if not owner then
					rec.plate = plate
				elseif not (owner.guid and rec.guid and owner.guid ~= rec.guid) then
					owner.unit = rec.unit
					owner.guid = owner.guid or rec.guid
					Absorb(owner, rec)
				end
			end
		end
	end
end

local function Prune()
	MergeDuplicates()
	local now = GetTime()
	if testUntil > 0 and testUntil < now then
		mobs.test = nil
		testUntil = 0
	end
	if not PlayerInCombat() then
		ClearAll()
		return
	end
	for key, rec in pairs(mobs) do
		if key ~= "test" then
			local drop
			local token = LiveToken(rec)
			if token then
				if Bool(UnitExists, token) == false then
					UnbindToken(token)
				elseif Bool(UnitIsDead, token) == true then
					drop = "dead"
				elseif not IsTrackableNPC(token) then
					UnbindToken(token)
				else
					local c = Bool(UnitAffectingCombat, token)
					if c == true then
						rec.seenInCombat = true
						rec.oocSince = nil
					elseif c == false and rec.seenInCombat then
						rec.oocSince = rec.oocSince or now
						if now - rec.oocSince >= OOC_GRACE then
							drop = "left combat"
						end
					end
				end
			end
			if not drop and not rec.paused and (rec.expires or 0) <= now then
				rec.zeroSince = rec.zeroSince or now
				if now - rec.zeroSince >= EXPIRE_GRACE then
					drop = "expired"
				end
			end
			if drop then
				DropKey(key, drop)
			end
		end
	end
end

function LH.GetRecord(key)
	return key and mobs[key]
end

function LH.EachMob(fn)
	for key, rec in pairs(mobs) do
		fn(key, rec)
	end
end

function LH.Remaining(rec)
	if not rec then
		return 0, 0
	end
	if rec.paused then
		return rec.pauseLeft or 0, rec.duration
	end
	local left = (rec.expires or 0) - GetTime()
	if left < 0 then
		left = 0
	end
	return left, rec.duration
end

function LH.TimerColor(remain, duration)
	local t = 0
	if duration and duration > 0 then
		t = remain / duration
	end
	if t > 0.45 then
		return 0.05, 0.82, 0.62
	elseif t > 0.22 then
		return 0.95, 0.78, 0.15
	end
	return 0.95, 0.22, 0.18
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

local function CopyDefaults(src, dest)
	dest = dest or {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			dest[k] = CopyDefaults(v, dest[k])
		elseif dest[k] == nil then
			dest[k] = v
		end
	end
	return dest
end

local function OrderedMobs()
	local list = {}
	for _, rec in pairs(mobs) do
		list[#list + 1] = rec
	end
	table.sort(list, function(a, b)
		return LH.Remaining(a) < LH.Remaining(b)
	end)
	return list
end

local function CanDrag()
	if not db then
		return false
	end
	return db.preview or not db.locked
end

local function ApplyLock()
	if not window then
		return
	end
	local drag = CanDrag()
	window:EnableMouse(drag)
	window:SetMovable(drag)
end

local PREVIEW_SAMPLES = {
	{ name = "Scorpashi Lasher", duration = 13, offset = 0, icon = "Interface\\Icons\\Ability_Hunter_Pet_Scorpid" },
	{ name = "Scorpashi Lasher", duration = 13, offset = 6.6, icon = "Interface\\Icons\\Ability_Hunter_Pet_Scorpid" },
	{ name = "Scorpashi Venomspitter", duration = 13, offset = 10.9, icon = "Interface\\Icons\\Ability_Hunter_Pet_Spider" },
}

local function PreviewList()
	local now = GetTime()
	local list = {}
	for i = 1, #PREVIEW_SAMPLES do
		local s = PREVIEW_SAMPLES[i]
		local remain = s.duration - ((now + s.offset) % s.duration)
		list[i] = {
			name = s.name,
			hasName = true,
			duration = s.duration,
			icon = s.icon,
			previewRemain = remain,
		}
	end
	return list
end

local function HasRealMobs()
	for key in pairs(mobs) do
		if key ~= "test" then
			return true
		end
	end
	return false
end

local function UpdatePreviewChrome()
	if not window then
		return
	end
	if not window.previewBg then
		local bg = window:CreateTexture(nil, "BACKGROUND")
		bg:SetColorTexture(0.02, 0.05, 0.07, 0.62)
		bg:SetPoint("TOPLEFT", -10, 22)
		bg:SetPoint("BOTTOMRIGHT", 10, -10)
		window.previewBg = bg
		local edges = {}
		local function edge(p1, p2, w, h)
			local t = window:CreateTexture(nil, "BORDER")
			t:SetColorTexture(12 / 255, 210 / 255, 157 / 255, 0.55)
			t:SetPoint(p1, bg, p1)
			t:SetPoint(p2, bg, p2)
			if w then
				t:SetWidth(w)
			end
			if h then
				t:SetHeight(h)
			end
			edges[#edges + 1] = t
		end
		edge("TOPLEFT", "TOPRIGHT", nil, 1)
		edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
		edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
		edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
		window.previewEdges = edges
		local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		pcall(hint.SetFont, hint, "Fonts\\ARIALN.TTF", 12, "OUTLINE")
		hint:SetPoint("BOTTOMLEFT", window, "TOPLEFT", 0, 6)
		hint:SetTextColor(12 / 255, 210 / 255, 157 / 255, 1)
		hint:SetText("Previsualize — drag to move")
		window.previewHint = hint
	end
	local on = db and db.preview and true or false
	window.previewBg:SetShown(on)
	for i = 1, #window.previewEdges do
		window.previewEdges[i]:SetShown(on)
	end
	window.previewHint:SetShown(on)
	if window.SetHitRectInsets then
		if on then
			window:SetHitRectInsets(-10, -10, -24, -10)
		else
			window:SetHitRectInsets(0, 0, 0, 0)
		end
	end
end

local function LayoutBar()
	if not window then
		return
	end
	window:SetWidth(db.width or 260)
end

local function NewRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(36)
	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	local timeFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	timeFs:SetJustifyH("LEFT")
	return { frame = row, icon = icon, name = name, time = timeFs }
end

local function SetIconTexture(row, path)
	row.icon:SetTexCoord(0, 1, 0, 1)
	if SetPortraitToTexture and pcall(SetPortraitToTexture, row.icon, path) then
		return
	end
	row.icon:SetTexture(path)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

-- Real mobs keep their own row frame (keyed by record), so a portrait is
-- painted once from a verified token and never re-read from a recycled one.
local function PaintIcon(row, rec)
	if rec.icon then
		if row.iconPath ~= rec.icon then
			SetIconTexture(row, rec.icon)
			row.iconPath = rec.icon
		end
		return
	end
	if row.owner ~= rec then
		row.owner = rec
		row.hasPortrait = false
		row.iconPath = nil
		rec.portraitDirty = true
	end
	if rec.portraitDirty then
		local token = LiveToken(rec)
		if token and SetPortraitTexture and IsTrackableNPC(token) then
			row.icon:SetTexCoord(0, 1, 0, 1)
			if pcall(SetPortraitTexture, row.icon, token) then
				row.hasPortrait = true
				row.iconPath = nil
				rec.portraitDirty = false
			end
		end
	end
	if not row.hasPortrait and row.iconPath ~= FALLBACK_ICON then
		SetIconTexture(row, FALLBACK_ICON)
		row.iconPath = FALLBACK_ICON
	end
end

function LH.LayoutRows(parent, pool, list)
	if not parent or not pool or not db then
		return 0
	end
	pool.keyed = pool.keyed or {}
	pool.indexed = pool.indexed or {}
	pool.free = pool.free or {}
	local font = db.font or "Fonts\\FRIZQT__.TTF"
	local fs = db.fontSize or 18
	local ns = db.nameSize or 12
	local showIcon = db.showPortraits and true or false
	local showName = db.showNames ~= false
	local iconSize = db.iconSize or 28
	local gap = 4
	local rowH = math.max(fs, showName and ns or 0, showIcon and iconSize or 0) + 4
	local maxW = db.width or 260
	local height = 0
	local usedW = 40
	local usedKeys = {}
	local nIndexed = 0
	for i = 1, #list do
		local rec = list[i]
		local row
		if rec.key then
			row = pool.keyed[rec.key]
			if not row then
				row = table.remove(pool.free) or NewRow(parent)
				pool.keyed[rec.key] = row
			end
			usedKeys[rec.key] = true
		else
			nIndexed = nIndexed + 1
			row = pool.indexed[nIndexed]
			if not row then
				row = NewRow(parent)
				pool.indexed[nIndexed] = row
			end
		end
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -height)
		row.frame:SetHeight(rowH)
		row.frame:Show()

		local x = 0
		if showIcon then
			row.icon:ClearAllPoints()
			row.icon:SetSize(iconSize, iconSize)
			row.icon:SetPoint("LEFT", row.frame, "LEFT", x, 0)
			PaintIcon(row, rec)
			row.icon:Show()
			x = x + iconSize + gap
		else
			row.icon:Hide()
		end

		pcall(row.name.SetFont, row.name, font, ns, "OUTLINE")
		pcall(row.time.SetFont, row.time, font, fs, "OUTLINE")
		row.name:ClearAllPoints()
		row.time:ClearAllPoints()
		if showName then
			local hasName = rec.hasName
			if hasName == nil and not IsSecret(rec.name) and type(rec.name) == "string" then
				hasName = true
			end
			if hasName then
				row.name:SetText(rec.name)
			else
				row.name:SetText("Mob")
			end
			row.name:Show()
		else
			row.name:Hide()
		end
		local remain, duration
		if rec.previewRemain then
			remain, duration = rec.previewRemain, rec.duration or 13
		else
			remain, duration = LH.Remaining(rec)
		end
		local r, g, b = LH.TimerColor(remain, duration)
		row.time:SetText(format("%.1f", remain))
		row.time:SetTextColor(r, g, b, 1)
		row.time:SetJustifyH("LEFT")
		row.name:SetTextColor(1, 1, 1, 0.95)
		local timeW = SafeNum(row.time:GetStringWidth()) or (fs * 2.4)
		if showName then
			local avail = math.max(maxW - x - gap - timeW, 24)
			local nameW = SafeNum(row.name:GetStringWidth()) or avail
			if nameW > avail then
				nameW = avail
			end
			row.name:SetWidth(nameW)
			row.name:SetPoint("LEFT", row.frame, "LEFT", x, 0)
			row.time:SetPoint("LEFT", row.name, "RIGHT", gap, 0)
			x = x + nameW + gap + timeW
		else
			row.time:SetPoint("LEFT", row.frame, "LEFT", x, 0)
			x = x + timeW
		end
		row.frame:SetWidth(x)
		if x > usedW then
			usedW = x
		end
		height = height + rowH
	end
	for i = nIndexed + 1, #pool.indexed do
		pool.indexed[i].frame:Hide()
	end
	for key, row in pairs(pool.keyed) do
		if not usedKeys[key] then
			row.frame:Hide()
			row.owner = nil
			row.hasPortrait = false
			pool.keyed[key] = nil
			pool.free[#pool.free + 1] = row
		end
	end
	parent:SetSize(math.max(usedW, 40), math.max(height, 20))
	return height, usedW
end

local function CreateWindow()
	if window then
		return
	end
	window = CreateFrame("Frame", "LeashHelperFrame", UIParent)
	window:SetSize(260, 36)
	window:SetPoint(db.point or "CENTER", UIParent, db.point or "CENTER", db.x or 0, db.y or 180)
	window:SetFrameStrata("HIGH")
	window:SetClampedToScreen(true)
	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", function(self)
		if not CanDrag() then
			return
		end
		self:StartMoving()
	end)
	window:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint()
		db.point, db.x, db.y = point, x, y
	end)
	ApplyLock()
	LayoutBar()
	UpdatePreviewChrome()
	window:Hide()
	LH.window = window
end

local function ShouldShowBar()
	if not db or not db.enabled then
		return false
	end
	if db.preview then
		return true
	end
	if testUntil > GetTime() then
		return true
	end
	if not AddonActive() then
		return false
	end
	return next(mobs) ~= nil
end

local function PaintWindow()
	if not window then
		return
	end
	local list = OrderedMobs()
	if db and db.preview and not HasRealMobs() then
		list = PreviewList()
	end
	if not ShouldShowBar() or #list == 0 then
		LH.LayoutRows(window, rows, {})
		window:Hide()
		return
	end
	window:Show()
	LH.LayoutRows(window, rows, list)
	UpdatePreviewChrome()
end

local function Tick()
	local ok, err = pcall(function()
		PauseIfCC()
		Prune()
		PaintWindow()
	end)
	if not ok then
		lastTickErr = tostring(err)
		Dbg("TICK ERROR %s", lastTickErr)
	end
end

local function StartTicker()
	if ticker then
		return
	end
	ticker = C_Timer.NewTicker(0.05, Tick)
end

---------------------------------------------------------------------------
-- Hit detection
---------------------------------------------------------------------------

local function HostileSpell(spellId, spellName)
	spellName = SafeStr(spellName)
	if spellName == "Auto Shot" or spellName == "Shoot" or spellName == "Attack" or spellName == "Auto Attack" then
		return true
	end
	if not IsHarmfulSpell then
		return false
	end
	for _, arg in ipairs({ spellId or false, spellName or false }) do
		if arg then
			local v = Bool(IsHarmfulSpell, arg)
			if v ~= nil then
				return v
			end
		end
	end
	return false
end

local SCHOOL_PHYSICAL = 1

local function PlayerIsSpellHeavy()
	if not UnitClass then
		return false
	end
	local ok, _, class = pcall(UnitClass, "player")
	if not ok then
		return false
	end
	class = SafeStr(class)
	return class == "MAGE" or class == "WARLOCK" or class == "PRIEST" or class == "HUNTER" or class == "SHAMAN"
end

-- Direct spell hits (Fireball landing) come ~0.5–2s after the cast. A
-- non-physical wound long after your last cast is a DoT tick, which does
-- not refresh the leash.
local SPELL_TRAVEL_WINDOW = 2.2

local function IsDotTick(action, school)
	if action ~= "WOUND" or not lastSpellCastAt or lastSpellCastAt <= 0 then
		return false
	end
	if GetTime() - lastSpellCastAt <= SPELL_TRAVEL_WINDOW then
		return false
	end
	school = SafeNum(school)
	if school then
		return school ~= SCHOOL_PHYSICAL
	end
	return PlayerIsSpellHeavy()
end

local HOSTILE_ACTIONS = {
	WOUND = true, MISS = true, DODGE = true, PARRY = true, BLOCK = true,
	RESIST = true, ABSORB = true, IMMUNE = true, DEFLECT = true, REFLECT = true,
}

local function HandleCombatHit(unit, action, _, _, school)
	unit = SafeStr(unit)
	action = SafeStr(action)
	if not unit or not action or not HOSTILE_ACTIONS[action] then
		return
	end
	if IsGroupToken(unit) then
		-- Something hit you or a group member. Only the target counts, and
		-- only when it is actually the one attacking us.
		if TargetingGroup("target") == true then
			LH.ResetLeash("target", "group-hit", true)
		else
			RefreshPack(nil, GetTime())
		end
		return
	end
	if IsDotTick(action, school) then
		Dbg("skip dot tick on %s", unit)
		return
	end
	LH.ResetLeash(unit, "combat")
end

---------------------------------------------------------------------------
-- Combat log (only where Forever allows it)
---------------------------------------------------------------------------

local band = bit and bit.band
local FLAG_GROUP = 0x00000007 -- mine | party | raid
local FLAG_CONTROL_PLAYER = 0x00000100
local FLAG_TYPE_NPC = 0x00000800

local function FlagsNPC(flags)
	flags = SafeNum(flags)
	return flags and band and band(flags, FLAG_TYPE_NPC) ~= 0 and band(flags, FLAG_CONTROL_PLAYER) == 0
end

local function FlagsGroup(flags)
	flags = SafeNum(flags)
	return flags and band and band(flags, FLAG_GROUP) ~= 0
end

local CLEU_HOSTILE = {
	SWING_DAMAGE = true, SWING_MISSED = true,
	RANGE_DAMAGE = true, RANGE_MISSED = true,
	SPELL_DAMAGE = true, SPELL_MISSED = true,
}

local function VisibleTokenForGuid(guid)
	local list = { "target", "focus", "pettarget" }
	for i = 1, 40 do
		list[#list + 1] = "nameplate" .. i
	end
	for i = 1, #list do
		if ReadableGUID(list[i]) == guid then
			return list[i]
		end
	end
	return nil
end

local function TouchGuid(guid, name, reason)
	local token = VisibleTokenForGuid(guid)
	if token and LH.ResetLeash(token, reason, true) then
		return
	end
	local now = GetTime()
	local rec = FindRecord(guid)
	if not rec then
		nextId = nextId + 1
		rec = { key = "m" .. nextId, guid = guid, seenInCombat = true }
		rec.duration = LH.DurationForLevel(Num(UnitLevel, "player"))
		mobs[rec.key] = rec
	end
	name = SafeStr(name)
	if name and name ~= "" then
		rec.name, rec.hasName = name, true
	end
	StartTimer(rec, now, nil)
	rec.reason = reason
	RefreshPack(rec, now)
end

local function HandleCLEU()
	if not AddonActive() or not CombatLogGetCurrentEventInfo then
		return
	end
	local ok, _, subevent, _, srcGUID, srcName, srcFlags, _, destGUID, destName, destFlags = pcall(CombatLogGetCurrentEventInfo)
	if not ok then
		return
	end
	subevent = SafeStr(subevent)
	srcGUID = SafeStr(srcGUID)
	destGUID = SafeStr(destGUID)
	if not subevent then
		return
	end
	if subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" or subevent == "PARTY_KILL" then
		if destGUID then
			DropByGuid(destGUID)
		end
		return
	end
	if not CLEU_HOSTILE[subevent] then
		return
	end
	if destGUID and FlagsGroup(srcFlags) and FlagsNPC(destFlags) then
		TouchGuid(destGUID, destName, "cleu")
	elseif srcGUID and FlagsGroup(destFlags) and FlagsNPC(srcFlags) then
		TouchGuid(srcGUID, srcName, "cleu")
	end
end

---------------------------------------------------------------------------
-- Options / test / debug
---------------------------------------------------------------------------

local function ApplyInstanceState()
	if not db then
		return
	end
	if db.disableInDungeons and InDungeon() and not db.preview then
		ClearAll()
		if window then
			window:Hide()
		end
	end
end

function LH.OnOptionChanged(key)
	CreateWindow()
	ApplyLock()
	LayoutBar()
	if key == "enabled" or key == "disableInDungeons" then
		ApplyInstanceState()
		if not AddonActive() and not (db and db.preview) then
			ClearAll()
			if window then
				window:Hide()
			end
		end
	end
	if key == "preview" then
		StartTicker()
	end
	if key == "debug" then
		if db.debug then
			LH.ShowDebug()
		elseif LH.debugFrame then
			LH.debugFrame:Hide()
		end
	end
	UpdatePreviewChrome()
	Tick()
	if LH.RefreshPreview then
		LH.RefreshPreview()
	end
end

function LH.StartTest()
	testUntil = GetTime() + 12
	mobs.test = {
		key = "test",
		duration = 11,
		expires = GetTime() + 11,
		name = "Scarlet Warrior",
		hasName = true,
		icon = TEST_ICON,
		paused = false,
	}
	CreateWindow()
	StartTicker()
	Tick()
end

local function Print(msg)
	print("|cff0cd29dLeashHelperForever|r: " .. msg)
end

local function Probe(unit)
	return format(
		"%s exists=%s dead=%s player=%s pctrl=%s atk=%s guid=%s plate=%s combat=%s track=%s",
		unit,
		Flag(Bool(UnitExists, unit)),
		Flag(Bool(UnitIsDead, unit)),
		Flag(Bool(UnitIsPlayer, unit)),
		Flag(Bool(UnitPlayerControlled, unit)),
		Flag(Bool(UnitCanAttack, "player", unit)),
		ReadableGUID(unit) and "readable" or "hidden",
		tostring(PlateTokenOf(unit)),
		Flag(Bool(UnitAffectingCombat, unit)),
		IsTrackableNPC(unit) and "yes" or "no"
	)
end

function LH.DumpState()
	local pos = "n/a"
	if db then
		pos = format("%s %.1f,%.1f", tostring(db.point), tonumber(db.x) or 0, tonumber(db.y) or 0)
	end
	local shown = window and window:IsShown()
	local lines = {
		"=== LeashHelperForever " .. VERSION .. " ===",
		format("enabled=%s preview=%s locked=%s debug=%s", Flag(db and db.enabled), Flag(db and db.preview), Flag(db and db.locked), Flag(db and db.debug)),
		format("inCombat=%s secrets=%s dungeon=%s active=%s", Flag(PlayerInCombat()), Flag(SecretsOn()), Flag(InDungeon()), Flag(AddonActive())),
		format("window=%s pos=%s", shown and "shown" or "hidden", pos),
		format("tickErr=%s", lastTickErr or "none"),
		"target: " .. Probe("target"),
		"pettarget: " .. Probe("pettarget"),
		"mobs:",
	}
	local n = 0
	for key, rec in pairs(mobs) do
		n = n + 1
		lines[#lines + 1] = format(
			"  %s name=%s left=%.1f guid=%s plate=%s unit=%s reason=%s",
			tostring(key),
			rec.hasName and Printable(rec.name) or "-",
			(LH.Remaining(rec)),
			rec.guid and "yes" or "no",
			tostring(rec.plate),
			tostring(rec.unit),
			tostring(rec.reason)
		)
	end
	if n == 0 then
		lines[#lines + 1] = "  (none)"
	end
	lines[#lines + 1] = "--- log ---"
	if #debugLines == 0 then
		lines[#lines + 1] = "(empty — pull a mob with Debug log on, then press Snapshot)"
	else
		for i = 1, #debugLines do
			lines[#lines + 1] = debugLines[i]
		end
	end
	return table.concat(lines, "\n")
end

local function CreateDebugWindow()
	if LH.debugFrame then
		return LH.debugFrame
	end
	local f = CreateFrame("Frame", "LeashHelperDebugFrame", UIParent)
	f:SetSize(520, 420)
	f:SetPoint("CENTER", 280, 0)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	local bg = f:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.07, 0.09, 0.97)
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	pcall(title.SetFont, title, "Fonts\\ARIALN.TTF", 16, "")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetTextColor(12 / 255, 210 / 255, 157 / 255, 1)
	title:SetText("LeashHelper debug")
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	pcall(hint.SetFont, hint, "Fonts\\ARIALN.TTF", 12, "")
	hint:SetPoint("TOPLEFT", 14, -32)
	hint:SetTextColor(1, 1, 1, 0.55)
	hint:SetText("Click the text, Ctrl+A then Ctrl+C, and paste it in chat")
	local close = CreateFrame("Button", nil, f)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -10, -10)
	local closeFs = close:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	pcall(closeFs.SetFont, closeFs, "Fonts\\ARIALN.TTF", 18, "")
	closeFs:SetPoint("CENTER", 0, 1)
	closeFs:SetText("×")
	close:SetScript("OnClick", function()
		f:Hide()
		if db then
			db.debug = false
			if LH.RefreshPreview then
				LH.RefreshPreview()
			end
		end
	end)
	local scroll = CreateFrame("ScrollFrame", "LeashHelperDebugScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -54)
	scroll:SetPoint("BOTTOMRIGHT", -36, 48)
	local edit = CreateFrame("EditBox", "LeashHelperDebugEdit", scroll)
	edit:SetMultiLine(true)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(450)
	edit:SetAutoFocus(false)
	edit:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	scroll:SetScrollChild(edit)
	f.edit = edit
	local function makeBtn(label, x)
		local b = CreateFrame("Button", nil, f)
		b:SetSize(90, 24)
		b:SetPoint("BOTTOMLEFT", x, 12)
		local bbg = b:CreateTexture(nil, "BACKGROUND")
		bbg:SetAllPoints()
		bbg:SetColorTexture(0.10, 0.12, 0.14, 1)
		local bfs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		pcall(bfs.SetFont, bfs, "Fonts\\ARIALN.TTF", 12, "")
		bfs:SetPoint("CENTER")
		bfs:SetText(label)
		return b
	end
	local snap = makeBtn("Snapshot", 14)
	snap:SetScript("OnClick", function()
		edit:SetText(LH.DumpState())
		edit:HighlightText()
		edit:SetFocus()
	end)
	local clr = makeBtn("Clear log", 112)
	clr:SetScript("OnClick", function()
		wipe(debugLines)
		lastTickErr = nil
		edit:SetText(LH.DumpState())
	end)
	local function Refresh()
		if f:IsShown() then
			edit:SetText(LH.DumpState())
		end
	end
	LH.RefreshDebug = Refresh
	f:SetScript("OnShow", Refresh)
	LH.debugFrame = f
	tinsert(UISpecialFrames, "LeashHelperDebugFrame")
	return f
end

function LH.ShowDebug()
	if db then
		db.debug = true
	end
	Dbg("debug window opened")
	CreateDebugWindow():Show()
	if LH.RefreshDebug then
		LH.RefreshDebug()
	end
end

SLASH_LEASHHELPER1 = "/leash"
SLASH_LEASHHELPER2 = "/leashhelper"

SlashCmdList.LEASHHELPER = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "help" then
		Print("commands:")
		print("  |cffffff00/leash|r - open options")
		print("  |cffffff00/leash lock|r - lock/unlock the display")
		print("  |cffffff00/leash test|r - preview an 11s timer")
		print("  |cffffff00/leash preview|r - toggle on-screen previsualize")
		print("  |cffffff00/leash debug|r - open copyable debug log")
		print("  |cffffff00/leash reset|r - reset position")
	elseif msg == "lock" or msg == "unlock" then
		db.locked = not db.locked
		ApplyLock()
		Print(db.locked and "locked." or "unlocked. Drag to move.")
	elseif msg == "preview" or msg == "previsualize" then
		db.preview = not db.preview
		LH.OnOptionChanged("preview")
		Print(db.preview and "previsualize on. Drag the timer to move it." or "previsualize off.")
	elseif msg == "debug" then
		LH.ShowDebug()
		Print("debug log open. Ctrl+A, Ctrl+C, then paste it here.")
	elseif msg == "test" then
		LH.StartTest()
		Print("showing a sample leash timer.")
	elseif msg == "reset" then
		db.point, db.x, db.y = "CENTER", 0, 180
		if window then
			window:ClearAllPoints()
			window:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
		end
		Print("position reset.")
	elseif LH.ToggleOptions then
		LH.ToggleOptions()
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local cleuFrame

local function SafeRegister(frame, event)
	pcall(frame.RegisterEvent, frame, event)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_COMBAT")
SafeRegister(eventFrame, "PLAYER_FOCUS_CHANGED")
SafeRegister(eventFrame, "ZONE_CHANGED_NEW_AREA")
SafeRegister(eventFrame, "UNIT_FLAGS")
SafeRegister(eventFrame, "UNIT_HEALTH")
SafeRegister(eventFrame, "UNIT_TARGET")
SafeRegister(eventFrame, "UNIT_PET")
SafeRegister(eventFrame, "UNIT_THREAT_SITUATION_UPDATE")
SafeRegister(eventFrame, "NAME_PLATE_UNIT_ADDED")
SafeRegister(eventFrame, "NAME_PLATE_UNIT_REMOVED")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then
			return
		end
		LeashHelperDB = CopyDefaults(defaults, LeashHelperDB)
		db = LeashHelperDB
		LH.db = db
		return
	end
	if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
		inCombat = Bool(InCombatLockdown) == true
		ClearAll()
		CreateWindow()
		if LH.CreateOptions then
			LH.CreateOptions()
		end
		StartTicker()
		if not SecretsOn() and not cleuFrame then
			cleuFrame = CreateFrame("Frame")
			cleuFrame:SetScript("OnEvent", HandleCLEU)
			SafeRegister(cleuFrame, "COMBAT_LOG_EVENT_UNFILTERED")
		end
		ApplyInstanceState()
		return
	end
	if event == "ZONE_CHANGED_NEW_AREA" then
		ApplyInstanceState()
		Tick()
		return
	end
	if event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
		ClearAll()
		Tick()
		return
	end
	if not AddonActive() then
		return
	end
	local unit = SafeStr(arg1)
	if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" or event == "UNIT_TARGET"
		or event == "UNIT_PET" or event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
		ResetPlateCache()
	end

	if event == "UNIT_COMBAT" then
		HandleCombatHit(arg1, arg2, arg3, arg4, arg5)
	elseif event == "PLAYER_REGEN_DISABLED" then
		Dbg("enter combat  %s", Probe("target"))
		-- A Fireball in the air is not a leash start; wait for a hit unless
		-- the mob is already running at us.
		if TargetingGroup("target") == true then
			LH.ResetLeash("target", "aggro")
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		UnbindToken("target")
		BindExisting("target")
	elseif event == "PLAYER_FOCUS_CHANGED" then
		UnbindToken("focus")
		BindExisting("focus")
	elseif event == "UNIT_PET" then
		UnbindToken("pettarget")
	elseif event == "UNIT_TARGET" then
		if unit == "pet" or (unit and unit:find("^party%d+$")) or (unit and unit:find("^raid%d+$")) then
			local token = unit .. "target"
			UnbindToken(token)
			BindExisting(token)
		elseif unit and unit ~= "player" and TargetingGroup(unit) == true then
			LH.ResetLeash(unit, "aggro")
		end
	elseif event == "UNIT_THREAT_SITUATION_UPDATE" then
		if TargetingGroup("target") == true then
			LH.ResetLeash("target", "aggro")
		end
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		if unit and next(mobs) then
			local guid = ReadableGUID(unit)
			local rec = guid and FindRecord(guid)
			if rec then
				Bind(rec, guid, unit, nil)
			end
		end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		-- Out of range is not a kill: unbind, and let the timer run out.
		if unit then
			if Bool(UnitIsDead, unit) == true then
				local rec = FindRecord(ReadableGUID(unit), unit, nil)
				if rec then
					DropKey(rec.key, "dead (plate removed)")
				end
			end
			UnbindToken(unit)
		end
	elseif event == "UNIT_HEALTH" or event == "UNIT_FLAGS" then
		if unit and next(mobs) and Bool(UnitIsDead, unit) == true then
			local rec = FindForUnit(unit)
			if rec then
				DropKey(rec.key, "dead")
			end
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit ~= "player" and unit ~= "pet" then
			return
		end
		local spellId = SafeNum(arg3)
		local name
		if GetSpellInfo and spellId then
			local ok, n = pcall(GetSpellInfo, spellId)
			if ok then
				name = n
			end
		end
		if HostileSpell(spellId, name) then
			lastSpellCastAt = GetTime()
		end
	end
end)
