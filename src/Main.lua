local addonName, PRT = ...

-- Access the PeaversCommons library
local PeaversCommons = _G.PeaversCommons

-- Initialize addon namespace
PRT.name = addonName
PRT.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "0.1.0"

--------------------------------------------------------------------------------
-- Slash commands
--
-- `test` is the headline command, not a debug hook. With boss-phase detection
-- unavailable and a real pull costing a raid night, replaying a ghost against a
-- synthetic clock out of combat is the only way to iterate on the list, the
-- cursor and the announcer — so it is documented in /prt help like any other.
--------------------------------------------------------------------------------

local function PrintStatus()
	local Utils = PeaversCommons.Utils
	local api = PRT.GetDataAPI()

	if not api then
		Utils.Print(PRT, "data addon: |cffff5555missing|r")
		return
	end

	local ok, updated = pcall(api.GetLastUpdate)
	Utils.Print(PRT, "data addon: loaded, timings updated " .. ((ok and updated) or "unknown"))

	local specID = PRT.Encounter:ResolvePlayerSpecID()
	Utils.Print(PRT, "your spec: " .. tostring(specID or "unresolved"))

	if not PRT.Encounter.active then
		Utils.Print(PRT, "no encounter running.")
		return
	end

	local timeline = PRT.Encounter.timeline
	Utils.Print(PRT, string.format("%s encounter %s at %.1fs - cast %d of %d",
		PRT.Encounter.synthetic and "replaying" or "tracking",
		tostring(PRT.Encounter.encounterID),
		PRT.Encounter:GetClock(),
		timeline:GetCursor(),
		timeline:GetCount()))

	-- Who, from where. The report/fight/region triple is what lets anyone go and
	-- watch the run this is replaying, so it belongs in the diagnostics too.
	local ghost = PRT.Encounter.ghost
	if ghost then
		Utils.Print(PRT, "following: " .. (PRT.DescribeGhost(ghost) or "?"))
		Utils.Print(PRT, string.format("source: report %s fight %s (%s)",
			tostring(ghost.report), tostring(ghost.fight), tostring(ghost.region)))

		local matched, total, average = timeline:GetScore()
		if average then
			Utils.Print(PRT, string.format("matched %d of %d casts, %+.1fs against them on average.",
				matched, total, average))
		else
			Utils.Print(PRT, string.format("matched 0 of %d casts so far.", total))
		end
	end

	local casts = PRT.CastWatch:GetRecentCasts()
	Utils.Print(PRT, string.format("%d of your casts seen this fight.", #casts))
end

PeaversCommons.SlashCommands:Register(addonName, "prt", {
	default = function()
		PRT.CueList:Toggle()
	end,
	-- Registered explicitly even though SlashCommands adds a `config` of its own.
	-- Its version resolves the addon table with _G[addonName], and this addon
	-- deliberately never publishes itself as a global — PeaversRaidTimingsDB is the
	-- only name it puts in _G — so that lookup returns nil and the handler bails
	-- out before reaching any of its fallbacks. The result was a documented command
	-- that silently did nothing. Calling ConfigUI directly is both correct and one
	-- less indirection.
	config = function()
		PRT.ConfigUI:OpenOptions()
	end,
	test = function(rest)
		PRT.Encounter:StartTest(rest)
	end,
	stop = function()
		PRT.Encounter:Stop("stopped.")
	end,
	status = function()
		PrintStatus()
	end,
})

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

PeaversCommons.Events:Init(addonName, function()
	PRT.Config:Initialize()

	-- The TOC hard-dependency normally guarantees the Data addon, but Curse
	-- installs can desync. Every consumer already handles a nil API, so say so
	-- plainly and stand down rather than erroring into someone's raid.
	if not PRT.HasData() then
		PRT.disabled = true
		PeaversCommons.Utils.Print(PRT,
			"PeaversRaidTimingsData is missing or outdated - nothing can be replayed until it is installed.")
	end

	if PRT.ConfigUI and PRT.ConfigUI.Initialize then
		PRT.ConfigUI:Initialize()
	end

	PRT.Announcer:Initialize()
	PRT.CastWatch:Initialize()
	PRT.CueList:Initialize()

	-- Encounter events are registered even when disabled: the addon should light
	-- up the moment the data addon is installed and the UI reloaded, and an
	-- ENCOUNTER_START with no data is a no-op that logs at debug level.
	PRT.Encounter:Initialize()

	-- Use the centralized SettingsUI system from PeaversCommons
	C_Timer.After(0.5, function()
		PeaversCommons.SettingsUI:CreateRedirectPage(PRT, addonName, "Peavers Raid Timings")
	end)

	-- Register with PeaversConfig registry
	if PeaversCommons.ConfigRegistry then
		PeaversCommons.ConfigRegistry:Register({
			name = addonName,
			displayName = "Raid Timings",
			description = "Race a top-ranked player's actual cast timeline for your spec",
			addonRef = PRT,
			config = PRT.Config,
			pages = PRT.ConfigUI:GetPages(),
			order = 10,
		})
	end
end, {
	suppressAnnouncement = true
})
