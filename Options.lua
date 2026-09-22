--[[
  Options window styled after EllesmereUI.
]]

local LH = _G.LeashHelper
if not LH then
	return
end

local UIFont = "Fonts\\ARIALN.TTF"

local function Accent()
	if EllesmereUI then
		if EllesmereUI.GetAccentColor then
			local r, g, b = EllesmereUI.GetAccentColor()
			if r then
				return r, g, b
			end
		end
		if EllesmereUI.DEFAULT_ACCENT_R then
			return EllesmereUI.DEFAULT_ACCENT_R, EllesmereUI.DEFAULT_ACCENT_G, EllesmereUI.DEFAULT_ACCENT_B
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
	local texs = {}
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
		texs[#texs + 1] = t
	end
	edge("TOPLEFT", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", nil, 1)
	edge("BOTTOMLEFT", "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT", nil, 1)
	edge("TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", 1, nil)
	edge("TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT", 1, nil)
	return {
		SetColor = function(_, cr, cg, cb, ca)
			for i = 1, #texs do
				texs[i]:SetColorTexture(cr, cg, cb, ca or 1)
			end
		end,
	}
end

local function Font(parent, size, r, g, b, a)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	pcall(fs.SetFont, fs, UIFont, size or 13, "")
	fs:SetTextColor(r or 1, g or 1, b or 1, a or 1)
	return fs
end

local function Tooltip(frame, title, body)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		if body then
			GameTooltip:AddLine(body, 0.85, 0.85, 0.85, true)
		end
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function Notify(key)
	if LH.OnOptionChanged then
		LH.OnOptionChanged(key)
	end
end

local optionsFrame
local openMenu

local function HideMenu()
	if openMenu then
		openMenu:Hide()
	end
end

local function MakeCheck(parent, label, key, tooltip, indent)
	local db = LH.db
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(24)
	local box = CreateFrame("Frame", nil, row)
	box:SetSize(14, 14)
	box:SetPoint("LEFT", row, "LEFT", indent or 0, 0)
	Fill(box, 0.075, 0.113, 0.141, 1)
	local brd = Border(box, 1, 1, 1, 0.25)
	local ar, ag, ab = Accent()
	local check = box:CreateTexture(nil, "ARTWORK")
	check:SetPoint("TOPLEFT", 3, -3)
	check:SetPoint("BOTTOMRIGHT", -3, 3)
	check:SetColorTexture(ar, ag, ab, 1)
	local lbl = Font(row, 13, 1, 1, 1, 0.86)
	lbl:SetPoint("LEFT", box, "RIGHT", 8, 0)
	lbl:SetText(label)
	row:SetWidth((indent or 0) + 14 + 8 + (lbl:GetStringWidth() or 120) + 8)
	row.enabled = true

	local function Paint()
		local on = db[key] and true or false
		check:SetShown(on)
		if not row.enabled then
			check:SetShown(on)
			brd:SetColor(1, 1, 1, 0.12)
			lbl:SetTextColor(1, 1, 1, 0.32)
		elseif on then
			brd:SetColor(ar, ag, ab, 0.85)
			lbl:SetTextColor(1, 1, 1, 0.86)
		else
			brd:SetColor(1, 1, 1, 0.25)
			lbl:SetTextColor(1, 1, 1, 0.86)
		end
	end
	Paint()
	row:SetScript("OnClick", function()
		if not row.enabled then
			return
		end
		db[key] = not (db[key] and true or false)
		Paint()
		Notify(key)
	end)
	Tooltip(row, label, tooltip)
	row.Paint = Paint
	row.SetEnabled = function(_, on)
		row.enabled = on and true or false
		Paint()
	end
	return row
end

local function MakeButton(parent, label, width)
	local ar, ag, ab = Accent()
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(width or 28, 24)
	local bg = Fill(btn, 0.10, 0.12, 0.14, 1)
	local brd = Border(btn, ar, ag, ab, 0.35)
	local fs = Font(btn, 12, 1, 1, 1, 0.9)
	fs:SetPoint("CENTER")
	fs:SetText(label)
	btn:SetScript("OnEnter", function()
		bg:SetColorTexture(0.14, 0.16, 0.18, 1)
		brd:SetColor(ar, ag, ab, 0.9)
		fs:SetTextColor(ar, ag, ab, 1)
	end)
	btn:SetScript("OnLeave", function()
		bg:SetColorTexture(0.10, 0.12, 0.14, 1)
		brd:SetColor(ar, ag, ab, 0.35)
		fs:SetTextColor(1, 1, 1, 0.9)
	end)
	return btn
end

local function MakeLabeledRow(parent, label)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(32)
	row:SetPoint("LEFT", parent, "LEFT", 0, 0)
	row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
	local fs = Font(row, 13, 1, 1, 1, 0.9)
	fs:SetPoint("LEFT", 0, 0)
	fs:SetPoint("RIGHT", row, "CENTER", -12, 0)
	fs:SetJustifyH("RIGHT")
	fs:SetText(label)
	row.label = fs
	return row
end

local function MakeDropdown(parent, width, items, getValue, setValue)
	local ar, ag, ab = Accent()
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(width, 26)
	local bg = Fill(btn, 0.07, 0.09, 0.11, 1)
	local brd = Border(btn, 1, 1, 1, 0.10)
	local lbl = Font(btn, 13, 1, 1, 1, 0.86)
	lbl:SetPoint("LEFT", 12, 0)
	lbl:SetPoint("RIGHT", -22, 0)
	lbl:SetJustifyH("LEFT")
	lbl:SetWordWrap(false)
	local arrow = Font(btn, 10, 1, 1, 1, 0.45)
	arrow:SetPoint("RIGHT", -8, 0)
	arrow:SetText("▼")

	local function CurrentLabel()
		local value = getValue()
		for i = 1, #items do
			if items[i][2] == value then
				return items[i][1]
			end
		end
		return items[1][1]
	end
	lbl:SetText(CurrentLabel())

	local menu = CreateFrame("Frame", nil, UIParent)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetToplevel(true)
	menu:SetClampedToScreen(true)
	menu:SetSize(width, 8 + #items * 24)
	Fill(menu, 0.06, 0.08, 0.10, 0.98)
	Border(menu, 1, 1, 1, 0.12)
	menu:Hide()
	menu:EnableMouse(true)

	for i, info in ipairs(items) do
		local item = CreateFrame("Button", nil, menu)
		item:SetHeight(24)
		item:SetPoint("TOPLEFT", 1, -4 - (i - 1) * 24)
		item:SetPoint("TOPRIGHT", -1, -4 - (i - 1) * 24)
		local hl = item:CreateTexture(nil, "ARTWORK")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0)
		local ifs = Font(item, 13, 1, 1, 1, 0.53)
		ifs:SetPoint("LEFT", 10, 0)
		pcall(ifs.SetFont, ifs, info[2], 13, "")
		ifs:SetText(info[1])
		item:SetScript("OnEnter", function()
			hl:SetColorTexture(1, 1, 1, 0.06)
			ifs:SetTextColor(1, 1, 1, 1)
		end)
		item:SetScript("OnLeave", function()
			hl:SetColorTexture(1, 1, 1, 0)
			ifs:SetTextColor(1, 1, 1, 0.53)
		end)
		item:SetScript("OnClick", function()
			setValue(info[2])
			lbl:SetText(info[1])
			menu:Hide()
		end)
	end

	btn:SetScript("OnEnter", function()
		brd:SetColor(ar, ag, ab, 0.7)
		lbl:SetTextColor(1, 1, 1, 1)
	end)
	btn:SetScript("OnLeave", function()
		brd:SetColor(1, 1, 1, 0.10)
		lbl:SetTextColor(1, 1, 1, 0.86)
	end)
	btn:SetScript("OnClick", function()
		if menu:IsShown() then
			menu:Hide()
			return
		end
		HideMenu()
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
		menu:Show()
		openMenu = menu
	end)
	return btn
end

local function MakeStepper(parent, label, key, minv, maxv)
	local db = LH.db
	local row = MakeLabeledRow(parent, label)
	local minus = MakeButton(row, "−", 28)
	minus:SetPoint("LEFT", row, "CENTER", -8, 0)
	local sizeText = Font(row, 13, 1, 1, 1, 0.95)
	sizeText:SetPoint("LEFT", minus, "RIGHT", 8, 0)
	sizeText:SetWidth(28)
	sizeText:SetJustifyH("CENTER")
	sizeText:SetText(tostring(db[key] or minv))
	local plus = MakeButton(row, "+", 28)
	plus:SetPoint("LEFT", sizeText, "RIGHT", 8, 0)
	local function bump(delta)
		local v = (db[key] or minv) + delta
		if v < minv then
			v = minv
		end
		if v > maxv then
			v = maxv
		end
		db[key] = v
		sizeText:SetText(tostring(v))
		Notify(key)
	end
	minus:SetScript("OnClick", function()
		bump(-1)
	end)
	plus:SetScript("OnClick", function()
		bump(1)
	end)
	return row
end

local function CreateOptions()
	if optionsFrame then
		return optionsFrame
	end
	local db = LH.db
	local ar, ag, ab = Accent()
	local f = CreateFrame("Frame", "LeashHelperOptions", UIParent)
	f:Hide()
	f:SetSize(460, 640)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	Fill(f, 0.05, 0.07, 0.09, 0.97)
	Border(f, ar, ag, ab, 0.45)
	tinsert(UISpecialFrames, "LeashHelperOptions")
	optionsFrame = f
	LH.optionsFrame = f

	local header = CreateFrame("Frame", nil, f)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(58)
	Fill(header, 0.055, 0.07, 0.09, 1)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function()
		f:StartMoving()
	end)
	header:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
	end)
	local accentLine = header:CreateTexture(nil, "ARTWORK")
	accentLine:SetPoint("BOTTOMLEFT")
	accentLine:SetPoint("BOTTOMRIGHT")
	accentLine:SetHeight(2)
	accentLine:SetColorTexture(ar, ag, ab, 1)

	local title = Font(header, 18, ar, ag, ab, 1)
	title:SetPoint("TOPLEFT", 18, -12)
	title:SetText("LeashHelperForever")

	local sub = Font(header, 12, 1, 1, 1, 0.45)
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	sub:SetText("Estimated chase timer for the mob you are fighting")

	local close = CreateFrame("Button", nil, header)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -12, -14)
	local closeFs = Font(close, 18, 1, 1, 1, 0.45)
	closeFs:SetPoint("CENTER", 0, 1)
	closeFs:SetText("×")
	close:SetScript("OnEnter", function()
		closeFs:SetTextColor(ar, ag, ab, 1)
	end)
	close:SetScript("OnLeave", function()
		closeFs:SetTextColor(1, 1, 1, 0.45)
	end)
	close:SetScript("OnClick", function()
		HideMenu()
		f:Hide()
	end)

	local body = CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 18, -16)
	body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)

	local opts = {
		{ "Enable addon", "enabled", "Master toggle." },
		{ "Lock", "locked", "Prevent dragging the display." },
		{ "Show portraits", "showPortraits", "Mob face on each row. Turn off for dense AoE packs." },
		{ "Show names", "showNames", "Mob name next to the timer." },
	}

	local last
	for i, info in ipairs(opts) do
		local row = MakeCheck(body, info[1], info[2], info[3])
		if last then
			row:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -5)
		else
			row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
		end
		last = row
	end

	local previewLabel = Font(body, 11, 1, 1, 1, 0.41)
	previewLabel:SetText("PREVIEW")
	previewLabel:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -14)
	local previewHint = Font(body, 11, 1, 1, 1, 0.32)
	previewHint:SetText("Sample pack — updates as you change options")
	previewHint:SetPoint("LEFT", previewLabel, "RIGHT", 10, 0)
	previewHint:SetPoint("RIGHT", body, "RIGHT", 0, 0)
	previewHint:SetJustifyH("RIGHT")

	local previewInset
	local insetOk = pcall(function()
		previewInset = CreateFrame("Frame", nil, body, "InsetFrameTemplate")
	end)
	if not insetOk or not previewInset then
		previewInset = CreateFrame("Frame", nil, body)
		Fill(previewInset, 0.10, 0.10, 0.10, 1)
		Border(previewInset, 0, 0, 0, 0.55)
	end
	previewInset:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 0, -6)
	previewInset:SetPoint("RIGHT", body, "RIGHT", 0, 0)
	previewInset:SetHeight(140)
	if previewInset.SetClipsChildren then
		previewInset:SetClipsChildren(true)
	end

	local previewHost = CreateFrame("Frame", nil, previewInset)
	previewHost:SetPoint("CENTER")
	local previewPool = {}
	local sample = {
		{ name = "Scorpashi Lasher", previewRemain = 11.0, duration = 13, icon = "Interface\\Icons\\Ability_Hunter_Pet_Scorpid" },
		{ name = "Scorpashi Lasher", previewRemain = 6.4, duration = 13, icon = "Interface\\Icons\\Ability_Hunter_Pet_Scorpid" },
		{ name = "Scorpashi Venomspitter", previewRemain = 2.1, duration = 13, icon = "Interface\\Icons\\Ability_Hunter_Pet_Spider" },
	}

	local function RefreshPreview()
		if not LH.LayoutRows then
			return
		end
		local h = LH.LayoutRows(previewHost, previewPool, sample)
		previewHost:ClearAllPoints()
		previewHost:SetPoint("CENTER", previewInset, "CENTER", 0, 0)
		previewInset:SetHeight(math.max(96, math.min((h or 80) + 24, 200)))
	end
	LH.RefreshPreview = RefreshPreview

	local fonts = {
		{ "Friz Quadrata", "Fonts\\FRIZQT__.TTF" },
		{ "Arial Narrow", "Fonts\\ARIALN.TTF" },
		{ "Morpheus", "Fonts\\MORPHEUS.TTF" },
		{ "Skurri", "Fonts\\SKURRI.TTF" },
	}

	local fontRow = MakeLabeledRow(body, "Font")
	fontRow:SetPoint("TOPLEFT", previewInset, "BOTTOMLEFT", 0, -12)
	local fontDrop = MakeDropdown(fontRow, 200, fonts, function()
		return db.font
	end, function(path)
		db.font = path
		Notify("font")
	end)
	fontDrop:SetPoint("LEFT", fontRow, "CENTER", -8, 0)

	local timerRow = MakeStepper(body, "Timer size", "fontSize", 10, 36)
	timerRow:SetPoint("TOPLEFT", fontRow, "BOTTOMLEFT", 0, -4)
	local nameRow = MakeStepper(body, "Name size", "nameSize", 8, 24)
	nameRow:SetPoint("TOPLEFT", timerRow, "BOTTOMLEFT", 0, -2)
	local iconRow = MakeStepper(body, "Portrait size", "iconSize", 16, 48)
	iconRow:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -2)
	local widthRow = MakeStepper(body, "Width", "width", 140, 400)
	widthRow:SetPoint("TOPLEFT", iconRow, "BOTTOMLEFT", 0, -2)

	local note = Font(body, 12, 1, 1, 1, 0.5)
	note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
	note:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)
	note:SetText("Each row is one mob you are fighting. When that mob leaves combat, its timer disappears even if you are still fighting something else.")

	f:SetScript("OnHide", HideMenu)
	f:SetScript("OnShow", function()
		RefreshPreview()
	end)
	C_Timer.After(0, RefreshPreview)
	return f
end

function LH.CreateOptions()
	return CreateOptions()
end

function LH.ToggleOptions()
	CreateOptions()
	if optionsFrame:IsShown() then
		HideMenu()
		optionsFrame:Hide()
	else
		optionsFrame:ClearAllPoints()
		optionsFrame:SetPoint("CENTER")
		optionsFrame:Show()
	end
end
