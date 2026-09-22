--[[
  Leash Helper for WoW Classic Forever

  Classic leash is a ~11–15s chase timer from last hostile action (or first
  melee after kiting while standing still). Forever blocks combat-log
  registration under secret restrictions, so this estimates from public
  events: UNIT_COMBAT, UNIT_SPELLCAST_SUCCEEDED, and (when allowed) CLEU.

  It is an estimate, matching the Wago "Leash helper" WeakAura intent.
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
	locked = false,
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
	return ok and SafeBool(v)
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

local function PersistableUnit(unit)
	if not unit or IsNameplateToken(unit) then
		return nil
	end
	return unit
end

local function Dead(unit)
	if not Exists(unit) then
		return false
	end
	local ok, v = pcall(UnitIsDead, unit)
	return ok and SafeBool(v)
end

local function Enemy(unit)
	if not Exists(unit) or Dead(unit) then
		return false
	end
	local ok, v = pcall(UnitCanAttack, "player", unit)
	return ok and SafeBool(v)
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

local function GuidKind(unit)
	local guid = SafeGUID(unit)
	if not guid then
		return nil
	end
	return guid:match("^(%a+)-")
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

local function CreatureTypeSafe(unit)
	if not Exists(unit) or not UnitCreatureType then
		return nil
	end
	local ok, t = pcall(UnitCreatureType, unit)
	if not ok then
		return nil
	end
	return SafeStr(t)
end

-- Only NPCs you can fight. Never the player, pet, party, or other players.
local function HostileNPC(unit)
	if not unit or not Exists(unit) or Dead(unit) then
		return false
	end
	if unit == "player" or unit == "pet" or IsGroupUnit(unit) then
		return false
	end
	local kind = GuidKind(unit)
	if kind == "Player" or kind == "Pet" then
		return false
	end
	if UnitIsPlayerSafe(unit) == true then
		return false
	end
	local myName = SafeName("player")
	local name = SafeName(unit)
	if myName and name and name == myName then
		return false
	end
	if UnitIsFriend then
		local ok, friend = pcall(UnitIsFriend, "player", unit)
		if ok and friend ~= nil and not IsSecret(friend) and friend then
			return false
		end
	end
	if Enemy(unit) then
		return true
	end
	-- Forever may hide UnitCanAttack on nameplates. Still allow a live plate
	-- only when we can prove it is an NPC, not a player.
	if inCombat and (IsNameplateToken(unit) or IsVolatileUnit(unit)) then
		if kind == "Creature" or kind == "Vehicle" then
			return true
		end
		if CreatureTypeSafe(unit) then
			return true
		end
		if UnitIsPlayerSafe(unit) == false then
			return true
		end
	end
	return false
end

local function RecIsNotNPC(rec)
	if not rec then
		return true
	end
	local u = rec.anchor or rec.unit
	if u and Exists(u) and not HostileNPC(u) then
		return true
	end
	if rec.guid and type(rec.guid) == "string" then
		if rec.guid:find("^Player-") or rec.guid:find("^Pet-") then
			return true
		end
	end
	local myName = SafeName("player")
	if myName and rec.name == myName then
		if u and Exists(u) and HostileNPC(u) then
			return false
		end
		return true
	end
	return false
end

local function StableAnchor(unit)
	if not unit or not Exists(unit) then
		return nil
	end
	if IsNameplateToken(unit) then
		return unit
	end
	for i = 1, 40 do
		local plate = "nameplate" .. i
		if Exists(plate) and SameUnit(plate, unit) then
			return plate
		end
	end
	if IsVolatileUnit(unit) then
		return nil
	end
	return unit
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

function LH.ResetLeash(unit, reason)
	if not db or not db.enabled then
		return
	end
	local key, token
	if unit then
		key, token = MobKey(unit)
	end
	if not key then
		local only, n = nil, 0
		for k in pairs(mobs) do
			if k ~= "test" then
				n = n + 1
				only = k
			end
		end
		if n == 1 then
			key = only
		else
			return
		end
	end
	lastFightKey = key
	local now = GetTime()
	local rec = mobs[key]
	local duration = LH.DurationForLevel(SafeLevel(token or unit))
	if rec and rec.duration then
		duration = rec.duration
		if token or (unit and Exists(unit)) then
			duration = LH.DurationForLevel(SafeLevel(token or unit))
		end
	end
	local cc = (token or unit) and AuraIsCC(token or unit)
	local persist = PersistableUnit(ResolvePublicUnit(token or unit) or token)
	local anchor = StableAnchor(token or unit)
	local guid = SafeGUID(token or unit)
	local name = SafeName(token or unit) or (persist and SafeName(persist)) or "Mob"
	if rec then
		rec.duration = duration
		rec.expires = now + duration
		if persist then
			rec.unit = persist
		end
		if anchor then
			rec.anchor = anchor
		end
		rec.name = name ~= "Mob" and name or rec.name
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

local function PauseIfCC()
	for _, rec in pairs(mobs) do
		local unit = rec.anchor or rec.unit
		if unit and Exists(unit) then
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
	if rec.anchor and Exists(rec.anchor) then
		return rec.anchor
	end
	if rec.guid then
		local found
		EachVisibleEnemy(function(unit)
			if found then
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
	return nil
end

-- Drop THIS mob when it leaves combat. Never steal another mob's timer.
local function DropIfLeftCombat(key, rec)
	if not rec or key == "test" then
		return false
	end
	if rec.unit and (not Exists(rec.unit) or IsVolatileUnit(rec.unit)) then
		rec.unit = nil
	end
	if rec.anchor and not Exists(rec.anchor) then
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

-- If we can see the pack, drop leftover rows that no longer have an in-combat
-- mob of that name (the one that leashed / ran out of plate range).
local function DropUnmatchedExtras()
	local byName = {}
	for key, rec in pairs(mobs) do
		if key ~= "test" then
			local name = rec.name or "?"
			byName[name] = byName[name] or {}
			byName[name][#byName[name] + 1] = { key = key, rec = rec }
		end
	end
	for name, list in pairs(byName) do
		local seenCombat = 0
		EachVisibleEnemy(function(u)
			if SafeName(u) == name and CombatState(u) == true then
				seenCombat = seenCombat + 1
			end
		end)
		if seenCombat == 0 then
			-- Pack is off-screen; keep timers until PLAYER_REGEN_ENABLED.
		else
			local anchored = 0
			local extras = {}
			for i = 1, #list do
				local rec = list[i].rec
				local a = rec.anchor
				if a and Exists(a) and CombatState(a) == true then
					anchored = anchored + 1
				else
					extras[#extras + 1] = list[i]
				end
			end
			table.sort(extras, function(a, b)
				return (a.rec.lastHit or 0) < (b.rec.lastHit or 0)
			end)
			local slots = seenCombat - anchored
			if slots < 0 then
				slots = 0
			end
			for i = 1, #extras - slots do
				DropKey(extras[i].key)
			end
		end
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
	DropUnmatchedExtras()
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

local function ApplyLock()
	if not window then
		return
	end
	window:EnableMouse(not db.locked)
	window:SetMovable(not db.locked)
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
		local view = rec.anchor or rec.unit
		if view and Exists(view) then
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
			elseif view and Exists(view) and SetPortraitTexture then
				pcall(SetPortraitTexture, row.icon, view)
			elseif not row.icon:GetTexture() then
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
		if db.locked then
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
	window:Hide()
	LH.window = window
end

local function ShouldShowBar()
	if not db.enabled then
		return false
	end
	if testUntil > GetTime() then
		return true
	end
	return next(mobs) ~= nil
end

local function PaintWindow()
	if not window then
		return
	end
	local list = OrderedMobs()
	if not ShouldShowBar() or #list == 0 then
		window:Hide()
		return
	end
	window:Show()
	rows = rows or {}
	LH.LayoutRows(window, rows, list)
end

local function Tick()
	PauseIfCC()
	Prune()
	PaintWindow()
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
	local resolved = ResolvePublicUnit(unit)
	-- Hits on you / your pet / group: refresh the mob you are fighting.
	-- Never start a timer on the player nameplate or another player.
	if IsGroupUnit(unit) or resolved == "player" or resolved == "pet" or IsGroupUnit(resolved) then
		if action == "WOUND" and PlayerStill() then
			if HostileNPC("target") then
				LH.ResetLeash("target", "melee-still")
			end
		end
		return
	end
	if action ~= "WOUND" and action ~= "DODGE" and action ~= "PARRY" and action ~= "MISS" and action ~= "BLOCK" and action ~= "RESIST" then
		return
	end
	local victim = resolved or unit
	if not HostileNPC(victim) then
		return
	end
	LH.ResetLeash(victim, "combat")
end

local function HandleCleU()
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
	ApplyLock()
	LayoutBar()
	if key == "enabled" and not db.enabled then
		ClearAll()
		if window then
			window:Hide()
		end
	end
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

SLASH_LEASHHELPER1 = "/leash"
SLASH_LEASHHELPER2 = "/leashhelper"

SlashCmdList.LEASHHELPER = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "help" then
		Print("commands:")
		print("  |cffffff00/leash|r - open options")
		print("  |cffffff00/leash lock|r - lock/unlock the display")
		print("  |cffffff00/leash test|r - preview an 11s timer")
		print("  |cffffff00/leash reset|r - reset position")
	elseif msg == "lock" or msg == "unlock" then
		db.locked = not db.locked
		ApplyLock()
		Print(db.locked and "locked." or "unlocked. Drag to move.")
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
SafeRegister(eventFrame, "UNIT_FLAGS")
SafeRegister(eventFrame, "NAME_PLATE_UNIT_ADDED")
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
		return
	end
	if not db or not db.enabled then
		return
	end
	if event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
		if HostileNPC("target") then
			LH.ResetLeash("target", "pull")
		end
		StartTicker()
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
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
		if Exists("target") then
			for _, rec in pairs(mobs) do
				if rec.anchor and SameUnit(rec.anchor, "target") then
					rec.unit = "target"
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
		local dest = unit == "pet" and "pettarget" or "target"
		if HostileNPC(dest) then
			LH.ResetLeash(dest, "cast")
		end
	elseif event == "UNIT_COMBAT" then
		HandleCombatHit(arg1, arg2)
	elseif event == "UNIT_AURA" then
		PauseIfCC()
	end
end)
