--------------------------------------------------------------------------------
-- PeaversRaidTimings settings
--
-- Display and announcement preferences ONLY. There is deliberately no timing
-- editor anywhere in this UI: the cast list is one ranked player's actual run and
-- is read-only. "Users cannot edit" means there is no in-game editing surface and
-- nothing timing-shaped is persisted — it does not mean the Lua on disk is
-- tamper-proof, and it would be dishonest to imply otherwise.
--------------------------------------------------------------------------------

local _, PRT = ...

local ConfigUI = {}
PRT.ConfigUI = ConfigUI

local PeaversCommons = _G.PeaversCommons
if not PeaversCommons then
	print("|cffff0000Error:|r PeaversCommons not found.")
	return
end

local W = PeaversCommons.Widgets

local function ResolveWidth(parentFrame, indent)
	local parentWidth = parentFrame:GetWidth() or 0
	if parentWidth > 100 then
		return parentWidth - (indent * 2) - 10
	end
	return 360
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

function ConfigUI:BuildDisplayPage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "Cast List", indent, y)
	y = newY - 8

	local checkboxes = {
		{ key = "showCueList", label = "Show the cast list" },
		{ key = "hideOutOfEncounter", label = "Hide the list outside an encounter" },
		{ key = "showHitMarkers", label = "Mark the casts you actually pressed" },
		{ key = "lockPosition", label = "Lock the list in place" },
	}

	for _, option in ipairs(checkboxes) do
		local checkbox = W:CreateCheckbox(parentFrame, option.label, {
			checked = PRT.Config[option.key],
			width = width,
			onChange = function(checked)
				PRT.Config[option.key] = checked
				PRT.Config:Save()
				PRT.CueList:ApplySettingsWithPreview()
			end,
		})
		checkbox:SetPoint("TOPLEFT", indent, y)
		y = y - 28
	end

	y = y - 8

	local sliders = {
		{
			key = "maxBars", label = "Casts shown at once",
			min = 1, max = 10, step = 1,
		},
		{
			key = "barWidth", label = "List width",
			min = 140, max = 400, step = 10,
			format = function(v) return math.floor(v + 0.5) .. " px" end,
		},
		{
			key = "barHeight", label = "Row height",
			min = 14, max = 40, step = 1,
			format = function(v) return math.floor(v + 0.5) .. " px" end,
		},
	}

	for _, option in ipairs(sliders) do
		local slider = W:CreateSlider(parentFrame, option.label, {
			min = option.min, max = option.max, step = option.step,
			value = PRT.Config[option.key],
			width = width,
			format = option.format,
			onChange = function(value)
				PRT.Config[option.key] = value
				PRT.Config:Save()
				PRT.CueList:ApplySettingsWithPreview()
			end,
		})
		slider:SetPoint("TOPLEFT", indent, y)
		y = y - 52
	end

	parentFrame:SetHeight(math.abs(y) + 30)
end

--------------------------------------------------------------------------------
-- Announcements
--------------------------------------------------------------------------------

function ConfigUI:BuildAnnouncementsPage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "Announcements", indent, y)
	y = newY - 8

	local checkboxes = {
		{ key = "announceEnabled", label = "Announce casts out loud" },
		{ key = "announceLeadIn", label = "Warn before the cast, not just on it" },
		{ key = "useTTS", label = "Use text-to-speech" },
		{ key = "soundFallback", label = "Play a sound when speech is unavailable" },
	}

	for _, option in ipairs(checkboxes) do
		local checkbox = W:CreateCheckbox(parentFrame, option.label, {
			checked = PRT.Config[option.key],
			width = width,
			onChange = function(checked)
				PRT.Config[option.key] = checked
				PRT.Config:Save()
			end,
		})
		checkbox:SetPoint("TOPLEFT", indent, y)
		y = y - 28
	end

	y = y - 8

	local leadInSlider = W:CreateSlider(parentFrame, "Lead-in warning", {
		min = 1, max = 10, step = 1,
		value = PRT.Config.leadInSeconds,
		width = width,
		format = function(v) return math.floor(v + 0.5) .. "s before" end,
		onChange = function(value)
			PRT.Config.leadInSeconds = value
			PRT.Config:Save()
		end,
	})
	leadInSlider:SetPoint("TOPLEFT", indent, y)
	y = y - 52

	local throttleSlider = W:CreateSlider(parentFrame, "Minimum gap between announcements", {
		min = 0.5, max = 5, step = 0.5,
		value = PRT.Config.announceThrottle,
		width = width,
		format = function(v) return string.format("%.1fs", v) end,
		onChange = function(value)
			PRT.Config.announceThrottle = value
			PRT.Config:Save()
		end,
	})
	throttleSlider:SetPoint("TOPLEFT", indent, y)
	y = y - 52

	local testButton = W:CreateButton(parentFrame, "Test the audio", {
		width = 160,
		onClick = function()
			if not PRT.Announcer:Test("Raid timings audio check") then
				PeaversCommons.Utils.Print(PRT, "no audio route available - text-to-speech and the sound fallback both failed.")
			end
		end,
	})
	testButton:SetPoint("TOPLEFT", indent, y)
	y = y - 40

	parentFrame:SetHeight(math.abs(y) + 30)
end

--------------------------------------------------------------------------------
-- The ghost
--
-- There are no data-quality controls here, and there should never be. Those
-- belonged to an aggregate timeline; what ships now is one ranked player's actual
-- cast list, so there is nothing to threshold. The only choices are how much of
-- the attribution and the race you want on screen.
--------------------------------------------------------------------------------

function ConfigUI:BuildGhostPage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "The Run You Are Following", indent, y)
	y = newY - 8

	local note = W:CreateLabel(parentFrame,
		"The cast list is one top-ranked player's actual run on this boss, replayed against your pull like a ghost car. It is their timings, not an average, and it cannot be edited.")
	note:SetPoint("TOPLEFT", indent, y)
	note:SetWidth(width)
	note:SetJustifyH("LEFT")
	y = y - 56

	local checkboxes = {
		{ key = "showGhostHeader", label = "Show who you are following" },
		{ key = "showDelta", label = "Show how far ahead or behind them you are" },
	}

	for _, option in ipairs(checkboxes) do
		local checkbox = W:CreateCheckbox(parentFrame, option.label, {
			checked = PRT.Config[option.key],
			width = width,
			onChange = function(checked)
				PRT.Config[option.key] = checked
				PRT.Config:Save()
				PRT.CueList:ApplySettingsWithPreview()
			end,
		})
		checkbox:SetPoint("TOPLEFT", indent, y)
		y = y - 28
	end

	parentFrame:SetHeight(math.abs(y) + 30)
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

function ConfigUI:GetPages()
	return {
		-- First entry renders leftmost and is the default-selected tab
		{ key = "display", label = "Display", builder = function(f) ConfigUI:BuildDisplayPage(f) end },
		{ key = "announcements", label = "Announcements", builder = function(f) ConfigUI:BuildAnnouncementsPage(f) end },
		{ key = "ghost", label = "Ghost", builder = function(f) ConfigUI:BuildGhostPage(f) end },
	}
end

-- Legacy single-panel path, kept for the older ConfigRegistry `buildPanel` contract.
function ConfigUI:BuildIntoFrame(parentFrame)
	self:BuildDisplayPage(parentFrame)
	return parentFrame
end

function ConfigUI:OpenOptions()
	local mainFrame = _G.PeaversConfig and _G.PeaversConfig.MainFrame
	if mainFrame then
		mainFrame:Show()
		if mainFrame.SelectAddon then
			mainFrame:SelectAddon("PeaversRaidTimings")
		end
		return
	end

	if Settings and Settings.OpenToCategory then
		if PRT.directSettingsCategoryID then
			local success = pcall(Settings.OpenToCategory, PRT.directSettingsCategoryID)
			if success then return end
		end
		if PRT.directCategoryID then
			local success = pcall(Settings.OpenToCategory, PRT.directCategoryID)
			if success then return end
		end
	end

	if SettingsPanel then
		SettingsPanel:Open()
	end
end

function ConfigUI:Initialize()
end
