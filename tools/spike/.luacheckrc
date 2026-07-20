-- PeaversRaidTimingsSpike luacheck config. Thin wrapper over the shared Peavers base (../wow-api).
-- The base supplies the lua51+wow standard, ignore/exclude policy, and stds.wow (WoW API:
-- generated from /papidump when present, else curated). allow_defined_top is off, so every
-- global this addon creates must be listed below — that list is its documented _G footprint.
-- Run: ../wow-api/scripts/lint.sh   (override package path with WOW_API_DIR)

local apiDir = (os and os.getenv and os.getenv("WOW_API_DIR")) or "../wow-api"
local base = assert(loadfile(apiDir .. "/config/luacheckrc.base.lua"))(apiDir)

std             = base.std
ignore          = base.ignore
exclude_files   = base.exclude
max_line_length = false
codestyle       = false
allow_defined_top = base.allow_defined_top
stds.wow        = base.wow

-- base.globals (PeaversChangelogs, SlashCmdList) + this addon's SavedVariables.
-- Deliberately short: the spike creates no public namespace table, only its save file.
-- Everything else it touches (C_CombatAudioAlert, C_EncounterTimeline, C_UnitAuras, C_TTSSettings,
-- C_VoiceChat, TextToSpeech_*, canaccessvalue, UnitCastingInfo, UnitClassification) is reached
-- through _G, because those exist in the 120007 dump but NOT in wow-api's curated floor — a
-- direct reference would fail degraded-mode lint.
globals = base.globals
for _, g in ipairs({"PeaversRaidTimingsSpikeDB"}) do globals[#globals + 1] = g end
