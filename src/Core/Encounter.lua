--------------------------------------------------------------------------------
-- Encounter — the fight clock and everything hanging off it
--
-- ENCOUNTER_START / ENCOUNTER_END are non-secret and still reliable on 12.0+,
-- which is why the whole design rests on them: they give the DungeonEncounterID,
-- the difficultyID, and the moment the clock starts. Everything else (spec,
-- ghost, bars, speech) is derived from that.
--
-- The clock is deliberately indirected through GetClock(). A real pull reads it
-- from GetTime(); /prt test drives the same field from a ticker. Both paths feed
-- the identical Timeline, Announcer, CastWatch and CueList code — that is what
-- makes the synthetic replay a real test rather than a parallel implementation.
--
-- Both paths also measure REAL elapsed time. C_Timer.NewTicker's interval is a
-- floor, not a promise: at 30fps a 0.1s ticker lands every ~0.13s, so a replay
-- that advanced by its nominal interval ran a quarter slow — on the one code path
-- whose entire job is to verify that timings are right.
--------------------------------------------------------------------------------

local _, PRT = ...

local PeaversCommons = _G.PeaversCommons

local Encounter = {}
PRT.Encounter = Encounter

local TICK_INTERVAL = 0.1

-- Difficulties tried in order when /prt test isn't told which one to use.
-- Mythic first: that is where the ranked logs the ghosts come from live.
local TEST_DIFFICULTY_FALLBACKS = { 16, 15, 14, 17, 23 }

Encounter.active = false
Encounter.synthetic = false
Encounter.timeline = nil
Encounter.ghost = nil
Encounter.encounterID = nil
Encounter.encounterName = nil
Encounter.difficultyID = nil
Encounter.specID = nil
Encounter.startTime = 0
Encounter.syntheticClock = 0
Encounter.lastTickAt = 0
Encounter.speed = 1.0
Encounter.ticker = nil

--------------------------------------------------------------------------------
-- Data addon access
--------------------------------------------------------------------------------

---The data addon's public API, or nil when it is missing or too old.
---Never errors — a Curse install can desync the hard dependency, and the addon
---has to survive that with a message rather than a stack trace.
---
---GetCasts and GetGhost are both required. An older data addon that still only
---publishes the pre-ghost aggregate API is deliberately treated as MISSING: the
---two schemas describe different things, and replaying a merged timeline as if
---it were somebody's run would be a lie about a named player.
---@return table|nil api
function PRT.GetDataAPI()
	local data = _G["PeaversRaidTimingsData"]
	if type(data) ~= "table" then return nil end

	local api = data.API
	if type(api) ~= "table" then return nil end
	if type(api.GetCasts) ~= "function" then return nil end
	if type(api.GetGhost) ~= "function" then return nil end

	return api
end

---@return boolean
function PRT.HasData()
	return PRT.GetDataAPI() ~= nil
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

---The player's current specialization ID (e.g. 256 for Discipline), or nil.
---@return number|nil specID
function Encounter:ResolvePlayerSpecID()
	local index
	if C_SpecializationInfo and type(C_SpecializationInfo.GetSpecialization) == "function" then
		local ok, result = pcall(C_SpecializationInfo.GetSpecialization)
		if ok then index = result end
	elseif type(GetSpecialization) == "function" then
		local ok, result = pcall(GetSpecialization)
		if ok then index = result end
	end
	if type(index) ~= "number" then return nil end

	local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo)
		or GetSpecializationInfo
	if type(getInfo) ~= "function" then return nil end

	local ok, specID = pcall(getInfo, index)
	if not ok or type(specID) ~= "number" then return nil end

	return specID
end

---Loads the ghost for one spec on one encounter: who we are following, and the
---cast list we are replaying. Both come back or neither does — a cast list with
---nobody's name on it is not a ghost, and the UI promises attribution.
---@param encounterID number
---@param difficultyID number
---@param specID number
---@return table|nil casts, table|nil ghost
function Encounter:LoadGhost(encounterID, difficultyID, specID)
	local api = PRT.GetDataAPI()
	if not api then return nil, nil end

	local gotCasts, casts = pcall(api.GetCasts, encounterID, difficultyID, specID)
	if not gotCasts or type(casts) ~= "table" or #casts == 0 then return nil, nil end

	local gotGhost, ghost = pcall(api.GetGhost, encounterID, difficultyID, specID)
	if not gotGhost or type(ghost) ~= "table" then return nil, nil end

	return casts, ghost
end

--------------------------------------------------------------------------------
-- The clock
--------------------------------------------------------------------------------

---Seconds since the pull. Zero when no encounter is running.
---@return number clock
function Encounter:GetClock()
	if not self.active then return 0 end
	if self.synthetic then return self.syntheticClock end
	return GetTime() - self.startTime
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---Starts a run. Shared by real pulls and /prt test — see options.synthetic.
---@param encounterID number
---@param difficultyID number
---@param options table|nil { synthetic, speed, startAt, specID, encounterName }
---@return boolean started, string|nil reason
function Encounter:Begin(encounterID, difficultyID, options)
	options = options or {}
	self:Stop()

	if PRT.disabled then
		return false, "PeaversRaidTimingsData is not loaded"
	end

	local specID = options.specID or self:ResolvePlayerSpecID()
	if not specID then
		return false, "could not resolve your specialization"
	end

	local casts, ghost = self:LoadGhost(encounterID, difficultyID, specID)
	if not casts then
		return false, string.format("no ghost for encounter %d, difficulty %d, spec %d",
			encounterID, difficultyID, specID)
	end

	self.encounterID = encounterID
	self.encounterName = options.encounterName
	self.difficultyID = difficultyID
	self.specID = specID
	self.ghost = ghost
	self.synthetic = options.synthetic and true or false
	self.speed = options.speed or 1.0

	local startAt = options.startAt or 0
	self.syntheticClock = startAt
	self.startTime = GetTime() - startAt
	self.lastTickAt = GetTime()

	self.timeline = PRT.Timeline:New(casts, {
		leadIn = PRT.Config.leadInSeconds or 4,
	})

	self.active = true

	PRT.Announcer:Reset()
	PRT.CastWatch:Attach(self.timeline, function() return self:GetClock() end)
	PRT.CueList:OnEncounterStart(self)

	self.ticker = C_Timer.NewTicker(TICK_INTERVAL, function()
		-- MEASURED, not nominal. See the header: the ticker's interval is a
		-- floor, so a replay stepping by TICK_INTERVAL drifts slow by however
		-- much the frame rate is costing us.
		local now = GetTime()
		local elapsed = now - (Encounter.lastTickAt or now)
		Encounter.lastTickAt = now

		local ok, err = pcall(Encounter.Tick, Encounter, elapsed)
		if not ok then
			PeaversCommons.Utils.Debug(PRT, "tick error:", tostring(err))
		end
	end)

	return true
end

---Ends the current run. Safe to call when nothing is running.
---@param reason string|nil printed when set
function Encounter:Stop(reason)
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end

	local wasActive = self.active

	self.active = false
	self.synthetic = false
	self.timeline = nil
	self.ghost = nil

	if PRT.CastWatch then PRT.CastWatch:Detach() end
	if PRT.Announcer then PRT.Announcer:Reset() end
	if PRT.CueList then PRT.CueList:OnEncounterStop() end

	if wasActive and reason then
		PeaversCommons.Utils.Print(PRT, reason)
	end
end

---One clock step. The only thing that differs between a real pull and a replay
---is which line moves the clock; everything below it is shared.
---@param elapsed number measured seconds since the previous tick
function Encounter:Tick(elapsed)
	if not self.active or not self.timeline then return end

	if self.synthetic then
		self.syntheticClock = self.syntheticClock + (elapsed * (self.speed or 1))
	end

	local clock = self:GetClock()

	for _, event in ipairs(self.timeline:Advance(clock)) do
		PRT.Announcer:Announce(event.entry, event.phase, clock)
	end

	PRT.CueList:Refresh(clock)

	if self.synthetic and self.timeline:IsFinished(clock) then
		self:Stop("test replay complete.")
	end
end

--------------------------------------------------------------------------------
-- Synthetic-clock replay — the primary development loop
--
-- With phase detection unavailable and a real pull costing a raid night, this is
-- how the list rendering, cursor advance, lead-in timing and TTS get iterated on.
-- It is a first-class feature, not a debug hook: it runs the production code path
-- end to end, only with the clock supplied by a ticker instead of the pull.
--------------------------------------------------------------------------------

---Handles "/prt test <encounterID> [difficultyID] [speed]".
---@param arguments string|nil
function Encounter:StartTest(arguments)
	local encounterID, difficultyID, speed = string.match(tostring(arguments or ""),
		"^%s*(%d*)%s*(%d*)%s*([%d%.]*)")

	encounterID = tonumber(encounterID)
	difficultyID = tonumber(difficultyID)
	speed = tonumber(speed) or PRT.Config.testSpeed or 1.0

	if not encounterID then
		PeaversCommons.Utils.Print(PRT, "usage: /prt test <encounterID> [difficultyID] [speed]")
		return
	end

	-- Out of combat only. The replay speaks and redraws freely; doing that during
	-- a real pull would talk over the calls that matter.
	if InCombatLockdown() then
		PeaversCommons.Utils.Print(PRT, "test replay is out-of-combat only.")
		return
	end

	local difficulties = difficultyID and { difficultyID } or TEST_DIFFICULTY_FALLBACKS

	-- The data API answers per (encounter, difficulty, spec) with no way to
	-- enumerate what it holds, so an unqualified /prt test walks the difficulties
	-- the ghosts are ranked on and takes the first that answers.
	local lastReason
	for _, candidate in ipairs(difficulties) do
		local started, reason = self:Begin(encounterID, candidate, {
			synthetic = true,
			speed = speed,
			encounterName = "Test replay",
		})
		if started then
			PeaversCommons.Utils.Print(PRT, string.format(
				"replaying %s (difficulty %d, spec %d) at %.1fx - %d casts. /prt stop to cancel.",
				PRT.DescribeGhost(self.ghost) or ("encounter " .. encounterID),
				candidate, self.specID or 0, speed, self.timeline:GetCount()))
			return
		end
		lastReason = reason
	end

	PeaversCommons.Utils.Print(PRT, "cannot replay: " .. tostring(lastReason))
end

--------------------------------------------------------------------------------
-- Attribution
--
-- We replay a named person's run, so their name travels with it everywhere it is
-- shown. One formatter, used by the list header, /prt status and the replay
-- banner, so those three can never disagree about who is being followed.
--------------------------------------------------------------------------------

---"252k" / "1.2m" / "840".
---@param total number|nil
---@return string|nil
function PRT.FormatTotal(total)
	if type(total) ~= "number" then return nil end
	if total >= 1000000 then return string.format("%.1fm", total / 1000000) end
	if total >= 1000 then return string.format("%dk", math.floor(total / 1000 + 0.5)) end
	return string.format("%d", math.floor(total + 0.5))
end

---"Awaken - rank 1 - 252k HPS", degrading field by field.
---@param ghost table|nil
---@return string|nil
function PRT.DescribeGhost(ghost)
	if type(ghost) ~= "table" then return nil end

	local parts = { tostring(ghost.player or "unknown") }

	if type(ghost.rank) == "number" then
		parts[#parts + 1] = "rank " .. tostring(ghost.rank)
	end

	local total = PRT.FormatTotal(ghost.total)
	if total then
		local metric = type(ghost.metric) == "string" and ghost.metric ~= "" and
			(" " .. string.upper(ghost.metric)) or ""
		parts[#parts + 1] = total .. metric
	end

	return table.concat(parts, " - ")
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Encounter:Initialize()
	PeaversCommons.Events:RegisterEvent("ENCOUNTER_START",
		function(_, encounterID, encounterName, difficultyID)
			-- A real pull always wins over a replay left running.
			if self.active and self.synthetic then
				self:Stop()
			end

			local started, reason = self:Begin(encounterID, difficultyID, {
				encounterName = encounterName,
			})
			if not started then
				PeaversCommons.Utils.Debug(PRT, "no ghost for this pull:", tostring(reason))
			end
		end)

	PeaversCommons.Events:RegisterEvent("ENCOUNTER_END", function()
		if self.active and not self.synthetic then
			self:Stop()
		end
	end)
end
