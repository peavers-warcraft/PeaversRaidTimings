--------------------------------------------------------------------------------
-- PeaversRaidTimings Configuration
-- Uses PeaversCommons.ConfigManager with AceDB-3.0 for profile management.
--
-- DISPLAY PREFERENCES ONLY. The ghost lives in PeaversRaidTimingsData and is
-- read-only: nothing here may write a cast or a time, and nothing timing-shaped
-- may ever be persisted into PeaversRaidTimingsDB. The settings below only decide
-- what is drawn and what is spoken.
--
-- Note there are no data-quality settings, and there must not be. The old
-- confidence/spread filters existed because the shipped timeline was a merge of
-- fifty logs; a ghost is one person's actual run, so there is nothing to filter
-- and no threshold that would mean anything.
--------------------------------------------------------------------------------

local _, PRT = ...

local PeaversCommons = _G.PeaversCommons
local ConfigManager = PeaversCommons.ConfigManager

local PRT_DEFAULTS = {
	-- Cast list display
	showCueList = true,
	maxBars = 5,
	barWidth = 240,
	barHeight = 24,
	barSpacing = 2,
	showHitMarkers = true,
	hideOutOfEncounter = true,
	lockPosition = false,

	-- The ghost itself. Attribution is on by default and should stay that way:
	-- these are a named player's timings and the UI says so.
	showGhostHeader = true,
	showDelta = true,

	-- Cast list position
	framePoint = "CENTER",
	frameRelativePoint = "CENTER",
	frameX = 320,
	frameY = 0,

	-- Announcements
	announceEnabled = true,
	useTTS = true,
	soundFallback = true,
	announceLeadIn = true,
	leadInSeconds = 4,
	announceThrottle = 1.5,

	-- Synthetic-clock replay (/prt test) — the primary development loop.
	testSpeed = 1.0,
	testDifficultyID = 16,

	DEBUG_ENABLED = false,
}

PRT.Config = ConfigManager:NewWithAceDB(
	PRT,
	PRT_DEFAULTS,
	{
		savedVariablesName = "PeaversRaidTimingsDB",
		profileType = "shared",
	}
)
