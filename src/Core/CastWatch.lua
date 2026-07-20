--------------------------------------------------------------------------------
-- CastWatch — did you actually press it?
--
-- UNIT_SPELLCAST_SUCCEEDED filtered to the player is the one spell-detection
-- channel that still works on 12.0+: the combat log is forbidden, boss unit events
-- are blocked during encounters, and C_EncounterTimeline's spellID is secret. The
-- player's own casts are never secret, so this is the half of the race we can see:
-- it is what turns the ghost from a list of times into a comparison, marking each
-- cast hit or missed and recording how far off the ghost it landed.
--
-- This module owns its own frame. PeaversCommons.Events multiplexes a single
-- shared frame and exposes no RegisterUnitEvent, and an *unfiltered*
-- UNIT_SPELLCAST_SUCCEEDED in a 20-player raid is a firehose we would be paying
-- for on every cast by every unit. RegisterUnitEvent moves that filter into the
-- client. Frame is anonymous and held in a local (NS001).
--
-- Every handler is pcall-wrapped: this fires mid-pull, and an error here must not
-- take the announcer or the cast list down with it.
--------------------------------------------------------------------------------

local _, PRT = ...

local PeaversCommons = _G.PeaversCommons

local CastWatch = {}
PRT.CastWatch = CastWatch

local watchFrame = CreateFrame("Frame")

local timeline = nil
local clockFn = nil
local recentCasts = {}

local MAX_RECENT = 40

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

---UNIT_SPELLCAST_SUCCEEDED handler. Signature: (unitTarget, castGUID, spellID).
function CastWatch:OnCastSucceeded(unitTarget, _, spellID)
	-- RegisterUnitEvent already filtered this, but the check is free and the
	-- addon must not credit the ghost's cast to somebody else's press.
	if unitTarget ~= "player" then return end
	if type(spellID) ~= "number" then return end

	-- 12.0+ can hand back secret values. Comparing or arithmetic on one errors,
	-- so bail before it reaches the timeline.
	if type(issecretvalue) == "function" and issecretvalue(spellID) then return end

	local clock = clockFn and clockFn() or 0

	recentCasts[#recentCasts + 1] = { spell = spellID, at = clock }
	if #recentCasts > MAX_RECENT then
		table.remove(recentCasts, 1)
	end

	if not timeline then return end

	local entry = timeline:MarkHit(spellID, clock)
	if entry then
		PeaversCommons.Utils.Debug(PRT, "matched", PRT.Spells:GetName(spellID),
			string.format("at %.1fs (ghost %.1fs, %+.1fs)", clock, entry.scheduled, entry.delta or 0))
		if PRT.CueList then
			PRT.CueList:Refresh(clock)
		end
	end
end

watchFrame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(CastWatch.OnCastSucceeded, CastWatch, ...)
	if not ok then
		PeaversCommons.Utils.Debug(PRT, "CastWatch error in", tostring(event), tostring(err))
	end
end)

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

function CastWatch:Initialize()
	self:Detach()
end

---Starts watching, crediting hits against `tl`. `clockSource` returns seconds
---since the pull — the same clock the timeline was advanced with, which is what
---makes the synthetic replay indistinguishable from a real pull here.
---@param tl table timeline
---@param clockSource fun(): number
function CastWatch:Attach(tl, clockSource)
	timeline = tl
	clockFn = clockSource
	recentCasts = {}

	-- An unknown or renamed event makes RegisterUnitEvent throw, and on modern
	-- clients can raise ADDON_ACTION_FORBIDDEN. Isolate it so a dead event name
	-- degrades to "no hit tracking" instead of a broken encounter.
	local ok, err = pcall(watchFrame.RegisterUnitEvent, watchFrame,
		"UNIT_SPELLCAST_SUCCEEDED", "player")
	if not ok then
		PeaversCommons.Utils.Print(PRT,
			"cast tracking unavailable (" .. tostring(err) .. ") - the ghost will still be shown and announced, but nothing can be compared against it.")
	end
end

---Stops watching. Safe to call when never attached.
function CastWatch:Detach()
	timeline = nil
	clockFn = nil
	pcall(watchFrame.UnregisterAllEvents, watchFrame)
end

---The player's recent casts this encounter, oldest first: { spell, at }.
---Read by /prt status — the fastest way to tell "the addon is deaf" apart from
---"the data is wrong" when a cast never matches the ghost.
---@return table casts
function CastWatch:GetRecentCasts()
	return recentCasts
end
