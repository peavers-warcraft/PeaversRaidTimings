-- PeaversRaidTimings luacheck config. Thin wrapper over the shared Peavers base (../wow-api).
-- The base supplies the lua51+wow standard, ignore/exclude policy, and stds.wow (WoW API:
-- generated from /papidump when present, else curated). allow_defined_top is off, so every
-- global this addon creates must be listed below — that list is its documented _G footprint.
-- Run: ../wow-api/scripts/lint.sh   (override package path with WOW_API_DIR)

local apiDir = (os and os.getenv and os.getenv("WOW_API_DIR")) or "../wow-api"
local loadBase = loadfile(apiDir .. "/config/luacheckrc.base.lua")

max_line_length = false
codestyle = false

if loadBase then
	local base = loadBase(apiDir)
	std = base.std
	ignore = base.ignore
	exclude_files = base.exclude
	allow_defined_top = base.allow_defined_top
	stds.wow = base.wow

	-- base.globals (PeaversChangelogs, SlashCmdList) + this addon's SavedVariables.
	-- PeaversRaidTimingsDB is the ONLY global this addon creates: display preferences
	-- only, never timing data. Slash commands are registered through PeaversCommons,
	-- which assigns SLASH_PRT1 via _G[...] on our behalf.
	globals = base.globals
	for _, g in ipairs({"PeaversRaidTimingsDB"}) do globals[#globals + 1] = g end
else
	-- Degraded mode without the ../wow-api checkout: syntax and local-variable
	-- checks still run, but the WoW API surface can't be validated, so global
	-- warnings (11x) are suppressed rather than false-positive on every C_* call.
	std = "lua51"
	allow_defined_top = true
	ignore = {"11"}
	exclude_files = {}
end

read_globals = {
	-- The data addon. Not in the shared base list yet (nor are PeaversGetThereData /
	-- PeaversIconSearchData — a pre-existing gap in wow-api/config/luacheckrc.base.lua
	-- worth closing in one pass). Declared here so this addon lints standalone.
	"PeaversRaidTimingsData",
	-- Present in the curated floor but absent from the generated /papidump (it is a
	-- Lua-side constants table, so the dumper's _G walk misses it).
	"SOUNDKIT",
	-- The TTS route the announcer uses. Both ARE in the generated dump
	-- (build/mainline/120007/wow-globals.lua), but the base only loads that dump
	-- when WOW_BUILD is set in the environment — unset, it falls back to the
	-- curated floor, which omits them. Declared here so the addon lints clean
	-- either way. The durable fix is to add them (and C_CombatAudioAlert) to
	-- wow-api/config/curated-globals.lua.
	"TextToSpeech_Speak",
	"TextToSpeech_GetSelectedVoice",
	-- Read only to turn a bare voice id back into the voice TABLE that
	-- TextToSpeech_Speak actually dereferences. Same curated-floor gap as the two
	-- above: present in the generated dump, absent unless WOW_BUILD is set.
	"C_VoiceChat",
}
