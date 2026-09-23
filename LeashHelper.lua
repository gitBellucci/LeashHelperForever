--[[
  Leash Helper for WoW Classic Forever

  Classic leash is a ~11–15s chase timer from last hostile action (or first
  melee after kiting while standing still). Linked packs share that timer:
  striking any one of them refreshes all of them (Vanilla / Classic hotfix).

  Forever blocks combat-log registration under secret restrictions, so this
  estimates from public events: UNIT_COMBAT, UNIT_SPELLCAST_SUCCEEDED, and
  (when allowed) CLEU.
]]

local ADDON_NAME = ...

local LH = {}
_G.LeashHelper = LH

local format = string.format
local wipe = wipe or table.wipe
local GetTime = GetTime
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitName = UnitName
local UnitLevel = UnitLevel
local UnitIsUnit = UnitIsUnit
local UnitIsDead = UnitIsDead
local UnitCanAttack = UnitCanAttack
local GetUnitSpeed = GetUnitSpeed
local GetNumGroupMembers = GetNumGroupMembers
local IsInRaid = IsInRaid
local IsInGroup = IsInGroup

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

local debugLines = {}
local lastTickErr
local DEBUG_MAX = 160

local function Dbg(fmt, ...)
	local msg = fmt
	if select("#", ...) > 0 then
		local ok, built = pcall(format, fmt, ...)
		if ok then
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

local db
local mobs = {}
local inCombat = false
local testUntil = 0
local lastFightKey
local nextSlot = 0
local window, ticker, rows
local playerGUID

local function IsSecret(v)
	return issecretvalue and issecretvalue(v)
end

local function SecretsOn()
	return C_Secrets and C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions()
end

local function SafeBool(v)
	if v == nil or IsSecret(v) then
		return false
	end
	if v then
		return true
	end
	return false
end

local function SafeNum(v)
	if v == nil or IsSecret(v) then
		return nil
	end
	return v
end

local function SafeStr(v)
	if v == nil or IsSecret(v) then
		return nil
	end
	if type(v) ~= "string" then
		return nil
	end
	return v
end

local function Exists(unit)
	if not unit then
		return false
	end
	local ok, v = pcall(UnitExists, unit)
	if not ok then
		return false
	end
	if v == nil or IsSecret(v) then
		-- Forever may hide UnitExists on target/pettarget. Do not treat that as "gone".
		return unit == "player" or unit == "pet" or unit == "target" or unit == "focus"
			or unit == "mouseover" or unit == "pettarget"
			or (type(unit) == "string" and unit:find("target$") ~= nil)
	end
	return v and true or false
end

-- 5-man dungeons only (instanceType "party"). Open world and raids stay on.
local function InDungeon()
	if not IsInInstance then
		return false
	end
	local ok, inInstance, instanceType = pcall(IsInInstance)
	if not ok then
		return false
	end
	instanceType = SafeStr(instanceType)
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

-- true / false / nil (secret or unknown). Never treat a secret as "out of combat".
local function CombatState(unit)
	if not Exists(unit) then
		return nil
	end
	if not UnitAffectingCombat then
		return nil
	end
	local ok, v = pcall(UnitAffectingCombat, unit)
	if not ok or v == nil or IsSecret(v) then
		return nil
	end
	if v then
		return true
	end
	return false
end

local function IsNameplateToken(unit)
	return type(unit) == "string" and unit:find("^nameplate") ~= nil
end

local function Dead(unit)
	if not unit or not Exists(unit) then
		return false
	end
	if UnitIsDead then
		local ok, v = pcall(UnitIsDead, unit)
		if ok and v ~= nil and not IsSecret(v) then
			return v and true or false
		end
	end
	if UnitHealth then
		local okh, h = pcall(UnitHealth, unit)
		h = okh and SafeNum(h) or nil
		if h == 0 then
			local maxh
			if UnitHealthMax then
				local okm, m = pcall(UnitHealthMax, unit)
				maxh = okm and SafeNum(m) or nil
			end
			if maxh == nil or maxh > 0 then
				return true
			end
		end
	end
	return false
end

local function Enemy(unit)
	if not Exists(unit) or Dead(unit) then
		return false
	end
	local ok, v = pcall(UnitCanAttack, "player", unit)
	return ok and SafeBool(v)
end

-- true / false / nil (secret). Nil must not be treated as "cannot attack".
local function AttackableState(unit)
	if not unit or Dead(unit) then
		return false
	end
	if not Exists(unit) then
		return false
	end
	local ok, v = pcall(UnitCanAttack, "player", unit)
	if not ok or v == nil or IsSecret(v) then
		return nil
	end
	if v then
		return true
	end
	return false
end

local function SameUnit(a, b)
	if not a or not b then
		return false
	end
	local ok, v = pcall(UnitIsUnit, a, b)
	return ok and SafeBool(v)
end

local function SafeGUID(unit)
	if not Exists(unit) then
		return nil
	end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok then
		return nil
	end
	return SafeStr(guid)
end

local function SafeName(unit)
	if not Exists(unit) then
		return nil
	end
	local ok, name = pcall(UnitName, unit)
	if not ok then
		return nil
	end
	return SafeStr(name)
end

local function SafeLevel(unit)
	if not Exists(unit) then
		return nil
	end
	local ok, level = pcall(UnitLevel, unit)
	if not ok then
		return nil
	end
	return SafeNum(level)
end

local function IsVolatileUnit(unit)
	return unit == "target" or unit == "focus" or unit == "mouseover" or unit == "pettarget"
		or (type(unit) == "string" and unit:find("target$") ~= nil and (unit:find("^party") or unit:find("^raid")))
end

local function UnitIsPlayerSafe(unit)
	if not Exists(unit) or not UnitIsPlayer then
		return nil
	end
	local ok, v = pcall(UnitIsPlayer, unit)
	if not ok or v == nil or IsSecret(v) then
		return nil
	end
	if v then
		return true
	end
	return false
end

local function PlayerControlledSafe(unit)
	if not Exists(unit) or not UnitPlayerControlled then
		return nil
	end
	local ok, v = pcall(UnitPlayerControlled, unit)
	if not ok or v == nil or IsSecret(v) then
		return nil
	end
	if v then
		return true
	end
	return false
end

local function GuidKind(unit)
	local guid = SafeGUID(unit)
	if not guid then
		return nil
	end
	return guid:match("^(%a+)-")
end

local function GuidIsPlayerOrPet(guid)
	if type(guid) ~= "string" then
		return false
	end
	return guid:find("^Player-") ~= nil or guid:find("^Pet-") ~= nil
end

local function IsGroupUnit(unit)
	if not unit or not Exists(unit) then
		return false
	end
	if unit == "player" or unit == "pet" or SameUnit(unit, "player") then
		return true
	end
	if Exists("pet") and SameUnit(unit, "pet") then
		return true
	end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			if SameUnit(unit, "raid" .. i) or SameUnit(unit, "raidpet" .. i) then
				return true
			end
		end
	elseif IsInGroup() then
		for i = 1, math.max(GetNumGroupMembers() - 1, 0) do
			if SameUnit(unit, "party" .. i) or SameUnit(unit, "partypet" .. i) then
				return true
			end
		end
	end
	return false
end

-- Players, pets, totems, and their nameplates. UnitIsUnit on plates is often
-- secret on Forever, so also match GUID / player-controlled / own name.
local function IsPlayerSide(unit)
	if not unit or not Exists(unit) then
		return false
	end
	if unit == "player" or unit == "pet" then
		return true
	end
	if type(unit) == "string" then
		if unit:find("^party%d+$") or unit:find("^raid%d+$") or unit:find("^partypet%d+$") or unit:find("^raidpet%d+$") then
			return true
		end
	end
	if IsGroupUnit(unit) then
		return true
	end
	local guid = SafeGUID(unit)
	if guid then
		if GuidIsPlayerOrPet(guid) then
			return true
		end
		if playerGUID and guid == playerGUID then
			return true
		end
		if Exists("pet") and guid == SafeGUID("pet") then
			return true
		end
	end
	if UnitIsPlayerSafe(unit) == true then
		return true
	end
	if PlayerControlledSafe(unit) == true then
		return true
	end
	if UnitIsOtherPlayersPet then
		local ok, otherPet = pcall(UnitIsOtherPlayersPet, unit)
		if ok and otherPet ~= nil and not IsSecret(otherPet) and otherPet then
			return true
		end
	end
	local myName = SafeName("player")
	local name = SafeName(unit)
	if myName and name and name == myName then
		return true
	end
	return false
end

local function IsPublicFightToken(unit)
	if not unit then
		return false
	end
	if unit == "target" or unit == "focus" or unit == "mouseover" or unit == "pettarget" then
		return true
	end
	return type(unit) == "string" and unit:find("target$") ~= nil and (unit:find("^party") or unit:find("^raid"))
end

-- Only world NPCs. Never players, pets, or player-controlled units.
-- CreatureType is not proof: warlock/hunter pets are Demon/Beast.
-- UnitCanAttack is not proof: nearby PvP players are attackable.
local function HostileNPC(unit)
	if not unit or not Exists(unit) or Dead(unit) then
		return false
	end
	if IsPlayerSide(unit) then
		return false
	end
	if UnitIsFriend then
		local ok, friend = pcall(UnitIsFriend, "player", unit)
		if ok and friend ~= nil and not IsSecret(friend) and friend then
			return false
		end
	end
	local kind = GuidKind(unit)
	if kind == "Player" or kind == "Pet" or kind == "Item" or kind == "GameObject" or kind == "Vignette" then
		return false
	end
	if kind == "Creature" or kind == "Vehicle" then
		if PlayerControlledSafe(unit) == true or UnitIsPlayerSafe(unit) == true then
			return false
		end
		return true
	end
	-- GUID hidden: never trust a random nameplate. Target / pettarget are OK
	-- unless proven to be a player or a non-attackable unit.
	if IsPublicFightToken(unit) then
		if UnitIsPlayerSafe(unit) == true or PlayerControlledSafe(unit) == true then
			return false
		end
		if AttackableState(unit) == false then
			return false
		end
		return true
	end
	if IsNameplateToken(unit) then
		local tokens = LH.PublicMobTokens()
		for i = 1, #tokens do
			if SameUnit(unit, tokens[i]) then
				return true
			end
		end
	end
	return false
end

local function PersistableUnit(unit)
	if not unit or IsNameplateToken(unit) or IsVolatileUnit(unit) then
		return nil
	end
	if not HostileNPC(unit) then
		return nil
	end
	return unit
end

local function Flag(v)
	if v == nil then
		return "nil"
	end
	if v == true then
		return "true"
	end
	if v == false then
		return "false"
	end
	return tostring(v)
end

local function Probe(unit)
	if not unit then
		return "nil"
	end
	if not Exists(unit) then
		return tostring(unit) .. " gone"
	end
	return format(
		"%s name=%s guid=%s kind=%s player=%s pctrl=%s atk=%s npc=%s side=%s",
		tostring(unit),
		SafeName(unit) or "?",
		SafeGUID(unit) or "?",
		GuidKind(unit) or "?",
		Flag(UnitIsPlayerSafe(unit)),
		Flag(PlayerControlledSafe(unit)),
		Flag(AttackableState(unit)),
		HostileNPC(unit) and "yes" or "no",
		IsPlayerSide(unit) and "yes" or "no"
	)
end

local function RecIsNotNPC(rec)
	if not rec then
		return true
	end
	if rec.guid and GuidIsPlayerOrPet(rec.guid) then
		return true
	end
	local myName = SafeName("player")
	if myName and rec.name == myName then
		return true
	end
	return false
end

local function StableAnchor(unit)
	if not unit or not Exists(unit) or not HostileNPC(unit) then
		return nil
	end
	if IsNameplateToken(unit) then
		return unit
	end
	for i = 1, 40 do
		local plate = "nameplate" .. i
		if Exists(plate) and HostileNPC(plate) and SameUnit(plate, unit) then
			return plate
		end
	end
	if IsVolatileUnit(unit) then
		return nil
	end
	return unit
end

local function ViewMatchesRec(rec, unit)
	if not rec or not unit or not Exists(unit) or Dead(unit) or not HostileNPC(unit) then
		return false
	end
	if rec.guid then
		local guid = SafeGUID(unit)
		return guid ~= nil and guid == rec.guid
	end
	-- Same name is not unique (two leopards). Only the stored token still
	-- pointing at this exact unit counts.
	if rec.anchor and (unit == rec.anchor or SameUnit(rec.anchor, unit)) then
		return true
	end
	return false
end

local function DisplayUnit(rec)
	if rec.anchor and ViewMatchesRec(rec, rec.anchor) then
		return rec.anchor
	end
	if rec.unit and ViewMatchesRec(rec, rec.unit) then
		return rec.unit
	end
	return nil
end

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

-- Crowd control that should pause the chase timer.
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
	if not Exists(unit) then
		return false
	end
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
			if not ok or not data then
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

function LH.PublicMobTokens()
	local list = {}
	local function add(token)
		if Exists(token) and HostileNPC(token) then
			list[#list + 1] = token
		end
	end
	add("target")
	add("focus")
	add("mouseover")
	add("pettarget")
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			add("raid" .. i .. "target")
		end
	elseif IsInGroup() then
		for i = 1, math.max(GetNumGroupMembers() - 1, 0) do
			add("party" .. i .. "target")
		end
	end
	return list
end

local function ResolvePublicUnit(unit)
	if not unit then
		return nil
	end
	unit = SafeStr(unit) or unit
	if unit == "player" or unit == "pet" then
		return unit
	end
	if unit == "target" or unit == "focus" or unit == "mouseover" or unit == "pettarget" then
		return unit
	end
	if type(unit) == "string" and unit:find("^nameplate") then
		local tokens = LH.PublicMobTokens()
		for i = 1, #tokens do
			if SameUnit(unit, tokens[i]) then
				return tokens[i]
			end
		end
		return nil
	end
	if type(unit) == "string" and (unit:find("^party") or unit:find("^raid")) then
		return unit
	end
	return unit
end

local function MobKey(unit)
	if not HostileNPC(unit) then
		return nil, nil
	end
	local guid = SafeGUID(unit)
	if guid then
		return guid, unit
	end
	for key, rec in pairs(mobs) do
		if key ~= "test" then
			if rec.guid and guid and rec.guid == guid then
				return key, unit
			end
			if rec.anchor and Exists(rec.anchor) and SameUnit(rec.anchor, unit) then
				return key, unit
			end
		end
	end
	nextSlot = nextSlot + 1
	return "mob" .. nextSlot, unit
end

local function PlayerStill()
	local ok, speed = pcall(GetUnitSpeed, "player")
	if not ok then
		return false
	end
	speed = SafeNum(speed)
	return speed ~= nil and speed < 1
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
	local left = rec.expires - GetTime()
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

-- Player/pet hit on one mob refreshes the whole fight (Classic linked packs).
local PACK_HIT_REASONS = {
	combat = true,
	cast = true,
	cleu = true,
	pull = true,
	["combat-fallback-target"] = true,
	["combat-fallback-pet"] = true,
}

local function RefreshPackLeashes(exceptKey, now)
	for key, rec in pairs(mobs) do
		if key ~= "test" and key ~= exceptKey then
			local dur = rec.duration or 11
			local unit = rec.anchor or rec.unit
			local cc = unit and Exists(unit) and not Dead(unit) and AuraIsCC(unit)
			if cc then
				rec.pauseLeft = dur
				rec.paused = true
			else
				rec.expires = now + dur
				rec.paused = false
				rec.pauseLeft = nil
			end
			rec.lastHit = now
			rec.seenInCombat = true
			rec.oocSince = nil
			rec.reason = "pack"
		end
	end
end

function LH.ResetLeash(unit, reason)
	if not AddonActive() then
		if db and db.debug then
			Dbg("reset skipped (addon off) %s", tostring(reason))
		end
		return
	end
	if not unit or not HostileNPC(unit) then
		if db and db.debug then
			Dbg("reset skip %s %s", tostring(reason), Probe(unit))
		end
		return
	end
	local key, token = MobKey(unit)
	if not key then
		if db and db.debug then
			Dbg("reset no-key %s %s", tostring(reason), Probe(unit))
		end
		return
	end
	lastFightKey = key
	local now = GetTime()
	local rec = mobs[key]
	local duration = LH.DurationForLevel(SafeLevel(token or unit))
	if rec and rec.duration then
		duration = rec.duration
		duration = LH.DurationForLevel(SafeLevel(token or unit))
	end
	local cc = AuraIsCC(token or unit)
	local persist = PersistableUnit(ResolvePublicUnit(token or unit) or token)
	local anchor = StableAnchor(token or unit)
	local guid = SafeGUID(token or unit)
	if guid and GuidIsPlayerOrPet(guid) then
		return
	end
	local name = SafeName(token or unit) or (persist and SafeName(persist))
	if not name or name == SafeName("player") then
		name = rec and rec.name or "Mob"
	end
	if rec then
		rec.duration = duration
		rec.expires = now + duration
		if persist then
			rec.unit = persist
		end
		if anchor then
			rec.anchor = anchor
		end
		if name ~= "Mob" then
			rec.name = name
		end
		rec.guid = guid or rec.guid
		rec.paused = cc and true or false
		rec.pauseLeft = cc and duration or nil
		rec.reason = reason
		rec.seenInCombat = true
		rec.oocSince = nil
		rec.lastHit = now
	else
		mobs[key] = {
			duration = duration,
			expires = now + duration,
			unit = persist,
			anchor = anchor,
			guid = guid,
			name = name,
			paused = cc and true or false,
			pauseLeft = cc and duration or nil,
			reason = reason,
			seenInCombat = true,
			lastHit = now,
		}
	end
	if db and db.debug then
		Dbg("reset %s key=%s name=%s dur=%.0f", tostring(reason), tostring(key), tostring(name), duration)
	end
	if reason and PACK_HIT_REASONS[reason] then
		RefreshPackLeashes(key, now)
	end
end

local function DropKey(key)
	if not key then
		return
	end
	mobs[key] = nil
	if lastFightKey == key then
		lastFightKey = nil
	end
end

local function ClearAll()
	wipe(mobs)
	lastFightKey = nil
end

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

local function PauseIfCC()
	for _, rec in pairs(mobs) do
		local unit = DisplayUnit(rec) or rec.unit
		if unit and Exists(unit) and HostileNPC(unit) then
			local cc = AuraIsCC(unit)
			if cc and not rec.paused then
				rec.pauseLeft = LH.Remaining(rec)
				rec.paused = true
			elseif rec.paused and not cc then
				rec.expires = GetTime() + (rec.pauseLeft or rec.duration)
				rec.paused = false
				rec.pauseLeft = nil
			end
		end
	end
end

local function EachVisibleEnemy(fn)
	local seen = {}
	local function consider(token)
		if not token or not Exists(token) or Dead(token) then
			return
		end
		if not HostileNPC(token) then
			return
		end
		local guid = SafeGUID(token)
		local id = guid or token
		if seen[id] then
			return
		end
		seen[id] = true
		fn(token)
	end
	local tokens = LH.PublicMobTokens()
	for i = 1, #tokens do
		consider(tokens[i])
	end
	for i = 1, 40 do
		consider("nameplate" .. i)
	end
end

local function LiveUnit(rec)
	if rec.anchor and ViewMatchesRec(rec, rec.anchor) then
		return rec.anchor
	end
	if rec.anchor then
		rec.anchor = nil
	end
	if rec.guid then
		local found
		EachVisibleEnemy(function(unit)
			if found or Dead(unit) then
				return
			end
			if SafeGUID(unit) == rec.guid then
				found = unit
			end
		end)
		if found then
			rec.anchor = StableAnchor(found) or rec.anchor
			return found
		end
	end
	if rec.unit and ViewMatchesRec(rec, rec.unit) then
		return rec.unit
	end
	return nil
end

-- Drop THIS mob when it leaves combat. Never steal another mob's timer.
local function DropIfLeftCombat(key, rec)
	if not rec or key == "test" then
		return false
	end
	if rec.unit and (not Exists(rec.unit) or IsVolatileUnit(rec.unit) or not HostileNPC(rec.unit)) then
		rec.unit = nil
	end
	if rec.anchor and (not Exists(rec.anchor) or not ViewMatchesRec(rec, rec.anchor)) then
		rec.anchor = nil
	end
	if rec.anchor and IsVolatileUnit(rec.anchor) then
		rec.anchor = StableAnchor(rec.anchor) or nil
	end

	local unit = LiveUnit(rec)
	if not unit then
		return false
	end
	if Dead(unit) then
		DropKey(key)
		return true
	end
	local combat = CombatState(unit)
	if combat == true then
		rec.seenInCombat = true
		rec.oocSince = nil
		local persist = PersistableUnit(ResolvePublicUnit(unit) or unit)
		if persist then
			rec.unit = persist
		end
		rec.name = SafeName(unit) or rec.name
		if rec.name == SafeName("player") then
			rec.name = "Mob"
		end
		return false
	end
	if combat == false and rec.seenInCombat then
		rec.oocSince = rec.oocSince or GetTime()
		if GetTime() - rec.oocSince >= 0.3 then
			DropKey(key)
			return true
		end
		return false
	end
	return false
end

-- One visible in-combat NPC can own at most one timer. Extra rows for the
-- same name (the leopard you just killed) are dropped while you stay in combat.
local function RebindVisibleMobs()
	local vis = {}
	local seenU = {}
	EachVisibleEnemy(function(u)
		if Dead(u) or CombatState(u) == false then
			return
		end
		local guid = SafeGUID(u)
		local id = guid or u
		if seenU[id] then
			return
		end
		seenU[id] = true
		vis[#vis + 1] = { unit = u, guid = guid, name = SafeName(u) or "?" }
	end)

	local used = {}
	local bound = {}

	local function claim(key, i)
		local rec = mobs[key]
		if not rec then
			return
		end
		used[i] = true
		bound[key] = i
		rec.anchor = StableAnchor(vis[i].unit) or rec.anchor
		if vis[i].guid then
			rec.guid = rec.guid or vis[i].guid
		end
		rec.oocSince = nil
	end

	for key, rec in pairs(mobs) do
		if key ~= "test" and rec.guid then
			for i = 1, #vis do
				if not used[i] and vis[i].guid == rec.guid then
					claim(key, i)
					break
				end
			end
		end
	end

	for key, rec in pairs(mobs) do
		if key ~= "test" and not bound[key] and rec.anchor and Exists(rec.anchor) and not Dead(rec.anchor) then
			for i = 1, #vis do
				if not used[i] and (rec.anchor == vis[i].unit or SameUnit(rec.anchor, vis[i].unit)) then
					claim(key, i)
					break
				end
			end
		end
	end

	local leftoverVis = {}
	for i = 1, #vis do
		if not used[i] then
			local n = vis[i].name
			leftoverVis[n] = leftoverVis[n] or {}
			leftoverVis[n][#leftoverVis[n] + 1] = i
		end
	end
	local leftoverRecs = {}
	for key, rec in pairs(mobs) do
		if key ~= "test" and not bound[key] then
			local n = rec.name or "?"
			leftoverRecs[n] = leftoverRecs[n] or {}
			leftoverRecs[n][#leftoverRecs[n] + 1] = key
		end
	end

	local visCount = {}
	for i = 1, #vis do
		visCount[vis[i].name] = (visCount[vis[i].name] or 0) + 1
	end

	local drop = {}
	for n, keys in pairs(leftoverRecs) do
		table.sort(keys, function(a, b)
			return (mobs[a].lastHit or 0) > (mobs[b].lastHit or 0)
		end)
		local slots = leftoverVis[n] or {}
		for j = 1, #keys do
			if j <= #slots then
				claim(keys[j], slots[j])
			elseif (visCount[n] or 0) > 0 then
				drop[#drop + 1] = keys[j]
			end
		end
	end
	for i = 1, #drop do
		if db and db.debug then
			Dbg("drop dead/extra %s", tostring(drop[i]))
		end
		DropKey(drop[i])
	end
end

local function DropCombatMobs()
	for key in pairs(mobs) do
		if key ~= "test" then
			DropKey(key)
		end
	end
end

local function Prune()
	if testUntil > 0 and testUntil < GetTime() then
		DropKey("test")
		testUntil = 0
	end
	if not inCombat then
		DropCombatMobs()
		return
	end
	for key, rec in pairs(mobs) do
		if key ~= "test" then
			if RecIsNotNPC(rec) then
				DropKey(key)
			else
				DropIfLeftCombat(key, rec)
			end
		end
	end
	RebindVisibleMobs()
end

local function Accent()
	if EllesmereUI and EllesmereUI.GetAccentColor then
		local r, g, b = EllesmereUI.GetAccentColor()
		if r then
			return r, g, b
		end
	end
	return 12 / 255, 210 / 255, 157 / 255
end

local function Fill(frame, r, g, b, a)
	local tex = frame:CreateTexture(nil, "BACKGROUND")
	tex:SetAllPoints()
	tex:SetColorTexture(r, g, b, a or 1)
	return tex
end

local function Border(frame, r, g, b, a)
	local function edge(p1, rp1, p2, rp2, w, h)
		local t = frame:CreateTexture(nil, "BORDER")
		t:SetColorTexture(r, g, b, a or 1)
		t:SetPoint(p1, frame, rp1)
		t:SetPoint(p2, frame, rp2)
		if w then
			t:SetWidth(w)
		end
		if h then
			t:SetHeight(h)
		end
	end
	edge("TOPLEFT", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", nil, 1)
	edge("BOTTOMLEFT", "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT", nil, 1)
	edge("TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", 1, nil)
	edge("TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT", 1, nil)
end

local function OrderedMobs()
	local list = {}
	for key, rec in pairs(mobs) do
		if key == "test" or not RecIsNotNPC(rec) then
			list[#list + 1] = rec
		end
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
		local edge = window:CreateTexture(nil, "BORDER")
		edge:SetColorTexture(12 / 255, 210 / 255, 157 / 255, 0.55)
		edge:SetPoint("TOPLEFT", bg, "TOPLEFT")
		edge:SetPoint("TOPRIGHT", bg, "TOPRIGHT")
		edge:SetHeight(1)
		window.previewEdgeT = edge
		local edgeB = window:CreateTexture(nil, "BORDER")
		edgeB:SetColorTexture(12 / 255, 210 / 255, 157 / 255, 0.55)
		edgeB:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT")
		edgeB:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT")
		edgeB:SetHeight(1)
		window.previewEdgeB = edgeB
		local edgeL = window:CreateTexture(nil, "BORDER")
		edgeL:SetColorTexture(12 / 255, 210 / 255, 157 / 255, 0.55)
		edgeL:SetPoint("TOPLEFT", bg, "TOPLEFT")
		edgeL:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT")
		edgeL:SetWidth(1)
		window.previewEdgeL = edgeL
		local edgeR = window:CreateTexture(nil, "BORDER")
		edgeR:SetColorTexture(12 / 255, 210 / 255, 157 / 255, 0.55)
		edgeR:SetPoint("TOPRIGHT", bg, "TOPRIGHT")
		edgeR:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT")
		edgeR:SetWidth(1)
		window.previewEdgeR = edgeR
		local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		pcall(hint.SetFont, hint, "Fonts\\ARIALN.TTF", 12, "OUTLINE")
		hint:SetPoint("BOTTOMLEFT", window, "TOPLEFT", 0, 6)
		hint:SetTextColor(12 / 255, 210 / 255, 157 / 255, 1)
		hint:SetText("Previsualize — drag to move")
		window.previewHint = hint
	end
	local on = db and db.preview
	window.previewBg:SetShown(on)
	window.previewEdgeT:SetShown(on)
	window.previewEdgeB:SetShown(on)
	window.previewEdgeL:SetShown(on)
	window.previewEdgeR:SetShown(on)
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

local function AcquireRow(parent, pool, i)
	if pool[i] then
		return pool[i]
	end
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(36)
	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local marker = row:CreateTexture(nil, "OVERLAY")
	local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	local timeFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	timeFs:SetJustifyH("LEFT")
	pool[i] = { frame = row, icon = icon, marker = marker, name = name, time = timeFs }
	return pool[i]
end

function LH.LayoutRows(parent, pool, list)
	if not parent or not pool or not db then
		return 0
	end
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
	for i = 1, #list do
		local rec = list[i]
		local view = DisplayUnit(rec)
		if view then
			rec.name = SafeName(view) or rec.name
		end
		local row = AcquireRow(parent, pool, i)
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -height)
		row.frame:SetHeight(rowH)
		row.frame:Show()

		local x = 0
		if showIcon then
			row.icon:ClearAllPoints()
			row.icon:SetSize(iconSize, iconSize)
			row.icon:SetPoint("LEFT", row.frame, "LEFT", x, 0)
			row.icon:Show()
			if rec.icon then
				row.icon:SetTexCoord(0, 1, 0, 1)
				local rounded = false
				if SetPortraitToTexture then
					rounded = pcall(SetPortraitToTexture, row.icon, rec.icon)
				end
				if not rounded then
					row.icon:SetTexture(rec.icon)
					row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
				end
			elseif view and SetPortraitTexture then
				pcall(SetPortraitTexture, row.icon, view)
			else
				row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
				row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			end
			x = x + iconSize + gap
		else
			row.icon:Hide()
		end

		if row.marker then
			row.marker:Hide()
		end

		pcall(row.name.SetFont, row.name, font, ns, "OUTLINE")
		pcall(row.time.SetFont, row.time, font, fs, "OUTLINE")
		row.name:ClearAllPoints()
		row.time:ClearAllPoints()
		if showName then
			row.name:SetText(rec.name or "Mob")
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
		local timeW = row.time:GetStringWidth() or (fs * 2.4)
		if showName then
			local nameW = row.name:GetStringWidth() or 40
			local avail = maxW - x - gap - timeW
			if avail < 24 then
				avail = 24
			end
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
	for i = #list + 1, #pool do
		pool[i].frame:Hide()
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
		window:Hide()
		return
	end
	window:Show()
	rows = rows or {}
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

local function StopTicker()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function HostileSpell(spellId, spellName)
	spellName = SafeStr(spellName)
	if spellName == "Auto Shot" or spellName == "Shoot" or spellName == "Attack" or spellName == "Auto Attack" then
		return true
	end
	if spellId and IsHarmfulSpell then
		local ok, v = pcall(IsHarmfulSpell, spellId)
		if ok then
			if IsSecret(v) then
				-- unknown
			elseif v then
				return true
			else
				return false
			end
		end
	end
	if spellName and IsHarmfulSpell then
		local ok, v = pcall(IsHarmfulSpell, spellName)
		if ok then
			if IsSecret(v) then
				-- unknown
			elseif v then
				return true
			else
				return false
			end
		end
	end
	return false
end

local function HandleCombatHit(unit, action)
	action = SafeStr(action)
	-- Hits on you / your pet / group / those nameplates: never start a timer
	-- on that unit. Pet melee on a mob still arrives as UNIT_COMBAT on the mob
	-- (or pettarget), not on the pet.
	if IsPlayerSide(unit) then
		if action == "WOUND" and PlayerStill() then
			if HostileNPC("target") then
				LH.ResetLeash("target", "melee-still")
			elseif HostileNPC("pettarget") then
				LH.ResetLeash("pettarget", "melee-still")
			end
		end
		return
	end
	if action ~= "WOUND" and action ~= "DODGE" and action ~= "PARRY" and action ~= "MISS" and action ~= "BLOCK" and action ~= "RESIST" then
		return
	end
	local victim = ResolvePublicUnit(unit) or unit
	if not HostileNPC(victim) then
		if db and db.debug then
			Dbg("combat skip %s %s", tostring(action), Probe(unit))
		end
		if HostileNPC("target") then
			LH.ResetLeash("target", "combat-fallback-target")
		elseif HostileNPC("pettarget") then
			LH.ResetLeash("pettarget", "combat-fallback-pet")
		end
		return
	end
	LH.ResetLeash(victim, "combat")
end

local function HandleCleU()
	if not AddonActive() then
		return
	end
	if not CombatLogGetCurrentEventInfo then
		return
	end
	local ok, _, subevent, _, srcGUID, _, _, _, destGUID = pcall(CombatLogGetCurrentEventInfo)
	if not ok then
		return
	end
	srcGUID = SafeStr(srcGUID)
	destGUID = SafeStr(destGUID)
	subevent = SafeStr(subevent)
	if not subevent or not destGUID then
		return
	end
	local mine = srcGUID and (srcGUID == playerGUID or (Exists("pet") and srcGUID == SafeGUID("pet")))
	local hostile = subevent == "SWING_DAMAGE" or subevent == "SWING_MISSED"
		or subevent == "RANGE_DAMAGE" or subevent == "RANGE_MISSED"
		or subevent == "SPELL_DAMAGE" or subevent == "SPELL_MISSED"
		or subevent == "SPELL_PERIODIC_DAMAGE"
		or subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH"
	if not mine or not hostile then
		return
	end
	if destGUID:find("^Player-") or destGUID:find("^Pet-") then
		return
	end
	if destGUID == playerGUID or (Exists("pet") and destGUID == SafeGUID("pet")) then
		return
	end
	-- Map dest GUID onto a public unit we can see.
	local tokens = LH.PublicMobTokens()
	for i = 1, #tokens do
		if SafeGUID(tokens[i]) == destGUID then
			LH.ResetLeash(tokens[i], "cleu")
			return
		end
	end
	if not mobs[destGUID] then
		mobs[destGUID] = {
			duration = 15,
			expires = GetTime() + 15,
			unit = nil,
			name = "Mob",
			paused = false,
			seenInCombat = true,
		}
	else
		local rec = mobs[destGUID]
		rec.expires = GetTime() + rec.duration
		rec.paused = false
		rec.seenInCombat = true
		rec.oocSince = nil
	end
	lastFightKey = destGUID
end

local events

local function SafeRegister(frame, event)
	pcall(frame.RegisterEvent, frame, event)
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
	mobs["test"] = {
		duration = 11,
		expires = GetTime() + 11,
		unit = nil,
		name = "Scarlet Warrior",
		paused = false,
	}
	lastFightKey = "test"
	CreateWindow()
	StartTicker()
	Tick()
end

local function Print(msg)
	print("|cff0cd29dLeashHelperForever|r: " .. msg)
end

function LH.DumpState()
	local pos = "n/a"
	if db then
		pos = format("%s %.1f,%.1f", tostring(db.point), tonumber(db.x) or 0, tonumber(db.y) or 0)
	end
	local shown = window and window:IsShown()
	local lines = {
		"=== LeashHelperForever 1.0.7 ===",
		format("enabled=%s preview=%s locked=%s debug=%s", Flag(db and db.enabled), Flag(db and db.preview), Flag(db and db.locked), Flag(db and db.debug)),
		format("inCombat=%s secrets=%s dungeon=%s active=%s", Flag(inCombat), Flag(SecretsOn()), Flag(InDungeon()), Flag(AddonActive())),
		format("window=%s pos=%s", shown and "shown" or "hidden", pos),
		format("tickErr=%s", lastTickErr or "none"),
		"target: " .. Probe("target"),
		"focus: " .. Probe("focus"),
		"pet: " .. Probe("pet"),
		"pettarget: " .. Probe("pettarget"),
		"mobs:",
	}
	local n = 0
	for k, rec in pairs(mobs) do
		n = n + 1
		local left = LH.Remaining(rec)
		lines[#lines + 1] = format("  %s name=%s left=%.1f guid=%s reason=%s", tostring(k), tostring(rec.name), left, tostring(rec.guid), tostring(rec.reason))
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
	else
		if LH.ToggleOptions then
			LH.ToggleOptions()
		end
	end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
SafeRegister(eventFrame, "PLAYER_FOCUS_CHANGED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_COMBAT")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
SafeRegister(eventFrame, "ZONE_CHANGED_NEW_AREA")
SafeRegister(eventFrame, "UNIT_FLAGS")
SafeRegister(eventFrame, "NAME_PLATE_UNIT_ADDED")
SafeRegister(eventFrame, "NAME_PLATE_UNIT_REMOVED")
SafeRegister(eventFrame, "UNIT_THREAT_SITUATION_UPDATE")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
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
		playerGUID = SafeGUID("player")
		CreateWindow()
		if LH.CreateOptions then
			LH.CreateOptions()
		end
		StartTicker()
		if not SecretsOn() then
			if not events then
				events = CreateFrame("Frame")
				events:SetScript("OnEvent", HandleCleU)
				pcall(events.RegisterEvent, events, "COMBAT_LOG_EVENT_UNFILTERED")
			end
		end
		ApplyInstanceState()
		return
	end
	if event == "ZONE_CHANGED_NEW_AREA" then
		ApplyInstanceState()
		Tick()
		return
	end
	if not AddonActive() then
		return
	end
	if event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
		if db and db.debug then
			Dbg("enter combat  %s", Probe("target"))
		end
		if HostileNPC("target") then
			LH.ResetLeash("target", "pull")
		elseif db and db.debug then
			Dbg("pull skipped, target not npc")
		end
		StartTicker()
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
		if db and db.debug then
			Dbg("leave combat")
		end
		DropCombatMobs()
		Tick()
	elseif event == "PLAYER_TARGET_CHANGED" then
		for _, rec in pairs(mobs) do
			if rec.unit == "target" then
				rec.unit = nil
			end
			if rec.anchor == "target" then
				rec.anchor = nil
			end
		end
		if Exists("target") and HostileNPC("target") then
			for _, rec in pairs(mobs) do
				if rec.anchor and SameUnit(rec.anchor, "target") then
					rec.unit = PersistableUnit("target")
				end
			end
		end
		Tick()
	elseif event == "PLAYER_FOCUS_CHANGED" then
		for _, rec in pairs(mobs) do
			if rec.unit == "focus" then
				rec.unit = nil
			end
			if rec.anchor == "focus" then
				rec.anchor = nil
			end
		end
		Tick()
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		local plate = SafeStr(arg1) or arg1
		for _, rec in pairs(mobs) do
			if rec.anchor == plate then
				rec.anchor = nil
			end
		end
		Tick()
	elseif event == "UNIT_FLAGS" or event == "NAME_PLATE_UNIT_ADDED" or event == "UNIT_THREAT_SITUATION_UPDATE" then
		Tick()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellId = arg1, arg2, arg3
		unit = SafeStr(unit) or unit
		spellId = SafeNum(spellId)
		if unit ~= "player" and unit ~= "pet" then
			return
		end
		local name
		if GetSpellInfo then
			local ok, n = pcall(GetSpellInfo, spellId)
			if ok then
				name = n
			end
		end
		if not HostileSpell(spellId, name) then
			return
		end
		local dest
		if unit == "pet" then
			dest = HostileNPC("pettarget") and "pettarget" or (HostileNPC("target") and "target")
		else
			dest = HostileNPC("target") and "target" or (HostileNPC("pettarget") and "pettarget")
		end
		if dest then
			LH.ResetLeash(dest, "cast")
		end
	elseif event == "UNIT_COMBAT" then
		HandleCombatHit(arg1, arg2)
	elseif event == "UNIT_AURA" then
		PauseIfCC()
	end
end)
