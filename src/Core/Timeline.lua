--------------------------------------------------------------------------------
-- Timeline — pure ghost scheduling logic
--
-- This file touches NO WoW API. Everything it needs arrives as arguments: a cast
-- list and a clock reading in seconds since the pull. That is deliberate — it is
-- the only part of the addon that can be unit-tested outside the client, and it
-- is where every ordering decision lives, so keep it that way. If you find
-- yourself reaching for GetTime(), C_Spell or a frame here, the logic belongs in
-- Encounter, CastWatch or CueList instead.
--
-- A cast as shipped by PeaversRaidTimingsData:
--   { spell = 10060, t = 45.2 }
--
-- `t` is SECONDS FROM THE PULL, transcribed verbatim from ONE named player's log.
-- There is no anchor, no confidence and no spread, because there is nothing to be
-- uncertain about: this is a recording of a run somebody actually gave, not an
-- aggregate of fifty runs nobody gave. Do not reintroduce averaging here.
--------------------------------------------------------------------------------

local _, PRT = ...

local Timeline = {}
Timeline.__index = Timeline
PRT.Timeline = Timeline

local DEFAULT_LEAD_IN = 4.0
local DEFAULT_ACTIVE_WINDOW = 3.0
local DEFAULT_HIT_TOLERANCE = 8.0
local DEFAULT_MISS_GRACE = 5.0

---@param casts table[] cast list from the data addon (never mutated)
---@param options table|nil { leadIn, activeWindow, hitTolerance, missGrace }
---@return table timeline
function Timeline:New(casts, options)
	options = options or {}

	local instance = setmetatable({}, Timeline)
	instance.leadIn = options.leadIn or DEFAULT_LEAD_IN
	instance.activeWindow = options.activeWindow or DEFAULT_ACTIVE_WINDOW
	instance.hitTolerance = options.hitTolerance or DEFAULT_HIT_TOLERANCE

	-- A cast goes "missed" once its moment is more than activeWindow old, and it
	-- leaves the screen at missGrace. Clamping missGrace above activeWindow is
	-- what makes the missed state REACHABLE rather than a colour nothing can ever
	-- render: with the two equal, a row drops out of GetUpcoming on the exact tick
	-- it would have turned red. Structural, not incidental — do not loosen it.
	instance.missGrace = math.max(options.missGrace or DEFAULT_MISS_GRACE,
		instance.activeWindow + 1.0)

	instance:Load(casts)
	return instance
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local function SortEntries(entries)
	table.sort(entries, function(a, b)
		if a.scheduled == b.scheduled then
			-- Ties break on the ghost's own order, NOT on spell id. The data addon
			-- ships one player's casts transcribed verbatim, and the generator has a
			-- dedicated test pinning that same-timestamp casts keep the log's order.
			-- Sorting by spell id here silently re-ordered them back at display time
			-- (Avatar/Recklessness inverted for Fury, among others), which broke the
			-- one guarantee the ghost makes. source holds the original position.
			return (a.source or 0) < (b.source or 0)
		end
		return a.scheduled < b.scheduled
	end)
	for i = 1, #entries do
		entries[i].index = i
	end
end

---Builds the working entry list from a shipped cast list. The source table is
---copied, not referenced: the data addon's table is shared and read-only.
function Timeline:Load(casts)
	local entries = {}

	if type(casts) == "table" then
		for position, cast in ipairs(casts) do
			if type(cast) == "table" and type(cast.spell) == "number" and type(cast.t) == "number" then
				entries[#entries + 1] = {
					spell = cast.spell,
					scheduled = cast.t,
					-- Position in the ghost's own cast list. Preserved so ties at the
					-- same timestamp render in the order the player actually cast them.
					source = position,
					warned = false,
					called = false,
					hit = false,
					hitAt = nil,
					-- Signed seconds between the player's cast and the ghost's:
					-- negative is ahead of the ghost, positive is behind it.
					delta = nil,
				}
			end
		end
	end

	SortEntries(entries)

	self.entries = entries
	self.cursor = 1
	return self
end

---Clears all per-run state (warned/called/hit/delta) without reloading the casts.
function Timeline:Reset()
	for _, entry in ipairs(self.entries) do
		entry.warned = false
		entry.called = false
		entry.hit = false
		entry.hitAt = nil
		entry.delta = nil
	end
	self.cursor = 1
	return self
end

--------------------------------------------------------------------------------
-- Advancing
--------------------------------------------------------------------------------

---Advances to `clock` and returns everything that became due since the last call.
---Each event is { entry = <entry>, phase = "warn" | "call" }.
---
---CALLS COME FIRST IN THE BATCH, AHEAD OF WARNINGS. When several casts cluster,
---both passes produce work on one tick, and a call is always about a cast due
---NOW while a warning is about one still seconds out. Emitting warnings first is
---what let a call arrive seconds after its moment.
---
---Idempotent per phase — calling twice with the same clock returns nothing the
---second time, so the caller can tick as often as it likes.
---@param clock number seconds since the pull
---@return table events
function Timeline:Advance(clock)
	local events = {}
	local entries = self.entries

	-- Call pass. The cursor moves only here.
	for i = self.cursor, #entries do
		local entry = entries[i]
		if entry.scheduled > clock then break end
		if not entry.called then
			entry.called = true
			events[#events + 1] = { entry = entry, phase = "call" }
		end
		self.cursor = i + 1
	end

	-- Warning pass. Looks further ahead than the call pass, so it deliberately
	-- scans past the cursor without moving it.
	--
	-- A cast that is ALREADY DUE is skipped rather than warned. Without that, a
	-- big clock jump — a resumed replay, a frame hitch — makes both passes fire
	-- for the same cast in the same batch, and "Barrier in 4" spoken at the
	-- instant Barrier is due is worse than saying nothing.
	if self.leadIn > 0 then
		for i = self.cursor, #entries do
			local entry = entries[i]
			if entry.scheduled - self.leadIn > clock then break end
			if not entry.warned and not entry.called and entry.scheduled > clock then
				entry.warned = true
				events[#events + 1] = { entry = entry, phase = "warn" }
			end
		end
	end

	return events
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

---True once `entry`'s moment has passed by more than the active window with no
---matching cast from the player. Rendered as the "missed" row state.
---@param entry table
---@param clock number
---@return boolean
function Timeline:IsMissed(entry, clock)
	if entry.hit then return false end
	return (clock - entry.scheduled) > self.activeWindow
end

---The next `count` casts to show at `clock`: everything still ahead, plus the
---ones just behind — that tail is what keeps a missed cast on screen long enough
---to register as missed.
---@param clock number
---@param count number|nil
---@return table entries
function Timeline:GetUpcoming(clock, count)
	local out = {}
	local limit = count or #self.entries

	for _, entry in ipairs(self.entries) do
		if entry.scheduled + self.missGrace >= clock then
			out[#out + 1] = entry
			if #out >= limit then break end
		end
	end

	return out
end

---Matches a cast the player actually made against the nearest unclaimed ghost
---cast of that spell, and records how far off the ghost they were. Returns the
---entry it credited, or nil when the cast was off-script.
---@param spellID number
---@param clock number
---@param tolerance number|nil seconds either side (defaults to hitTolerance)
---@return table|nil entry
function Timeline:MarkHit(spellID, clock, tolerance)
	if type(spellID) ~= "number" or type(clock) ~= "number" then return nil end
	tolerance = tolerance or self.hitTolerance

	local best, bestDelta
	for _, entry in ipairs(self.entries) do
		if entry.spell == spellID and not entry.hit then
			local delta = math.abs(entry.scheduled - clock)
			if delta <= tolerance and (bestDelta == nil or delta < bestDelta) then
				best, bestDelta = entry, delta
			end
		end
	end

	if best then
		best.hit = true
		best.hitAt = clock
		-- The whole point of the addon in one number: negative means you got
		-- there before the player you are following, positive means after.
		best.delta = clock - best.scheduled
	end

	return best
end

---@return table entries the live entry list (shared — treat as read-only)
function Timeline:GetEntries()
	return self.entries
end

---@return number count
function Timeline:GetCount()
	return #self.entries
end

---@return number cursor index of the first cast not yet called
function Timeline:GetCursor()
	return self.cursor
end

---How the run is going against the ghost so far.
---@return number matched, number total, number|nil averageDelta
function Timeline:GetScore()
	local matched, sum = 0, 0
	for _, entry in ipairs(self.entries) do
		if entry.hit and entry.delta then
			matched = matched + 1
			sum = sum + entry.delta
		end
	end
	if matched == 0 then return 0, #self.entries, nil end
	return matched, #self.entries, sum / matched
end

---True once every cast has been called and the tail has left the screen.
---Used by the synthetic-clock replay to stop itself.
---@param clock number
---@return boolean
function Timeline:IsFinished(clock)
	local last = self.entries[#self.entries]
	if not last then return true end
	return self.cursor > #self.entries and clock > last.scheduled + self.missGrace
end

---Seconds until `entry` fires (negative once it has passed).
---@param entry table
---@param clock number
---@return number
function Timeline:TimeUntil(entry, clock)
	return entry.scheduled - clock
end
