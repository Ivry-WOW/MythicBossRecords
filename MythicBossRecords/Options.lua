local ADDON, ns = ...

-- =====================================================================
--  Mythic Boss Records - settings panel
--  Game Menu > Interface > AddOns > Mythic Boss Records, the "Settings"
--  button in the main window, or /mbr settings
-- =====================================================================

local format = string.format

local Options = {}
ns.Options = Options

local panel = CreateFrame("Frame", "MythicBossRecordsOptions", UIParent)
panel.name = "Mythic Boss Records"
panel:Hide()
Options.panel = panel

local checks = {}
local y = -16

local function Header(text)
	local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetPoint("TOPLEFT", 16, y)
	fs:SetText(text)
	y = y - 22
	return fs
end

local function Check(label, tip, get, set)
	local cb = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
	cb:SetPoint("TOPLEFT", 20, y)
	local text = cb.Text
	if type(text) ~= "table" then text = _G[(cb:GetName() or "") .. "Text"] end
	if type(text) ~= "table" then
		text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
	end
	text:SetText(label)
	cb.tooltipText = tip
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	cb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(label, 1, 1, 1)
		GameTooltip:AddLine(tip, 1, 0.82, 0, true)
		GameTooltip:Show()
	end)
	cb:SetScript("OnLeave", GameTooltip_Hide)
	cb.get = get
	checks[#checks + 1] = cb
	y = y - 28
	return cb
end

local function S() return ns.db.settings end

function Options:Build()
	if self.built then return end
	self.built = true

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("Mythic Boss Records")
	local ver = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ver:SetPoint("LEFT", title, "RIGHT", 8, -1)
	ver:SetText("V." .. ns.VERSION .. "  -  Made by Ivry")
	y = y - 34

	Header("Sync")
	Check("Sync with my guild", "Share records live with guild members who have the addon, and catch up at login.",
		function() return ns.Sync:GetOption("guild") end, function(v) ns.Sync:SetOption("guild", v) end)
	Check("Sync with everyone on the server", "Share records with every player who has the addon, through a hidden chat channel (MBRSync). Turn off to leave the channel.",
		function() return ns.Sync:GetOption("global") end, function(v) ns.Sync:SetOption("global", v) end)
	Check("Sync with my friend list", "Whispers records to online friends who have the addon. Usually not needed: friends are reached through the server sync. Off by default.",
		function() return ns.Sync:GetOption("friends") end, function(v) ns.Sync:SetOption("friends", v) end)

	y = y - 8
	Header("Recording")
	Check("Announce my new records in chat", "Chat message when you get a top spot on a boss.",
		function() return S().announce end, function(v) S().announce = v end)

	y = y - 8
	Header("Display")
	Check("Show the minimap button", "Click: open / close the window. Drag: move it around the minimap.",
		function() return not S().minimap.hide end,
		function(v) S().minimap.hide = not v; if ns.UI.UpdateMinimapButton then ns.UI:UpdateMinimapButton() end end)

	-- records kept per spec
	local slider = CreateFrame("Slider", "MythicBossRecordsOptionsTop", panel, "OptionsSliderTemplate")
	slider:SetPoint("TOPLEFT", 26, y - 14)
	slider:SetWidth(220)
	slider:SetMinMaxValues(1, 25)
	slider:SetValueStep(1)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	local sname = slider:GetName() or "MythicBossRecordsOptionsTop"
	if _G[sname .. "Low"] then _G[sname .. "Low"]:SetText("1") end
	if _G[sname .. "High"] then _G[sname .. "High"]:SetText("25") end
	local stext = _G[sname .. "Text"] or slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	if not _G[sname .. "Text"] then stext:SetPoint("BOTTOM", slider, "TOP", 0, 2) end
	slider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value + 0.5)
		stext:SetText("Records kept per spec (Tyrannical / Fortified): " .. value)
		if ns.db and S().maxPerSpec ~= value and Options.ready then
			S().maxPerSpec = value
			ns.PruneAll()
			if ns.UI.Refresh then ns.UI:Refresh() end
		end
	end)
	self.slider = slider
	y = y - 64

	-- buttons
	local function Button(text, x, fn)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(130, 22)
		b:SetPoint("TOPLEFT", x, y)
		b:SetText(text)
		b:SetScript("OnClick", fn)
		return b
	end
	Button("Open window", 20, function() ns.UI:Toggle() end)
	Button("Who has the addon", 156, function() ns.Users:Toggle() end)
	Button("Sync now", 292, function() ns.Sync:Command("sync", "now") end)
	y = y - 34

	local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", 20, y)
	self.status = status
end

function Options:Refresh()
	if not ns.db then return end
	self:Build()
	self.ready = false
	for _, cb in ipairs(checks) do cb:SetChecked(cb.get() and true or false) end
	self.slider:SetValue(S().maxPerSpec or 5)
	self.ready = true
	self.status:SetText(format("Saved records: |cffffffff%d|r      %s", ns.CountRecords(), ns.Sync:StatusText()))
end

panel:SetScript("OnShow", function() Options:Refresh() end)

function Options:Open()
	self:Build()
	if InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(panel)
		InterfaceOptionsFrame_OpenToCategory(panel) -- the first call only opens the frame
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
	Options:Build()
	if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel) end
end)
