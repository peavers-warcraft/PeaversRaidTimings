--------------------------------------------------------------------------------
-- Announcer — lead-in warning, then the cast call
--
-- Three rules govern this file:
--
-- 1. ASSUME NOTHING ABOUT THE API. Every call out is feature-detected and then
--    pcall-guarded anyway. The TTS surface moved twice in 12.0 (C_VoiceChat's
--    signature changed, C_CombatAudioAlert.SpeakText is AllowedWhenUntainted and
--    so may be uncallable from addon code at all), so the WeakAuras indirection —
--    TextToSpeech_Speak with a voice from TextToSpeech_GetSelectedVoice — is the
--    path chosen because it is the one that survived. It may still vanish; when it
--    does, this must fall back to a sound, not error into a raid.
--
--    The exact signature matters and is easy to get wrong:
--        TextToSpeech_Speak(text, voice, neverQueue, allowOverlappedSpeech)
--    `voice` is a VOICE TABLE, not an id — Blizzard's own implementation reads
--    voice.voiceID off it. Passing the id speaks nothing, and because the call is
--    pcall'd it fails without erroring, so a bare `pcall` result is NOT evidence
--    that anything was said. That is how an audio-only addon ends up completely
--    silent with a clean log. Validate the voice BEFORE the call, and treat any
--    doubt as "not spoken" so the sound fallback gets its turn.
--
-- 2. WE OWN THE ORDERING. The engine's speech queue is documented as neither FIFO
--    nor LIFO, so nothing here may depend on it. Messages go through our own
--    priority queue and our own throttle, one at a time.
--
-- 3. LATE IS WORSE THAN NEVER. This addon sells timing; an announcement that
--    arrives after its moment is not a degraded version of the product, it is
--    actively misleading. So the queue is ordered by urgency rather than arrival,
--    stale items are DROPPED rather than drained, and the countdown number is
--    computed when the message is spoken, never baked in when it was queued.
--
--    "Stale" is PER PHASE, and it has to be — a single leadIn-wide window let a
--    clustered call be spoken a full lead-in after its cast was due, which is the
--    exact failure this rule names. See LatenessBudget: a call is worth saying
--    while the cast is still worth making, a warning only while there is still a
--    countdown left to say. An item that survives to the front of the queue and
--    is then found to be worthless must also not cost the queue a throttle
--    interval, or dropping work would slow the queue down instead of speeding it
--    up. See the tail of Drain.
--
-- Note GetCVarBool("textToSpeech") gates only the *chat* TTS pipeline, so addon
-- speech is expected to work with it switched off. Worth confirming in game
-- rather than trusting.
--------------------------------------------------------------------------------

local _, PRT = ...

local PeaversCommons = _G.PeaversCommons

local Announcer = {}
PRT.Announcer = Announcer

local queue = {}
local lastSpokenAt = 0
local drainScheduled = false

-- Below this many seconds remaining, a lead-in warning has nothing left to count
-- down and BuildMessage refuses to build one. Shared with the staleness test so
-- the queue drops such a warning instead of carrying it to the front and
-- discovering there was never anything to say.
local WARN_SPEAK_FLOOR = 0.5

-- Fallback for the window inside which a due cast is still worth calling, used
-- only when there is no live timeline to ask. Mirrors Timeline's own default.
local DEFAULT_ACTIVE_WINDOW = 3.0

--------------------------------------------------------------------------------
-- Output channels
--------------------------------------------------------------------------------

---Looks up the full voice table for a bare voice id, for the clients where
---TextToSpeech_GetSelectedVoice hands back an id instead of the table.
---@param voiceID number
---@return table|nil voice
local function VoiceForID(voiceID)
	if C_VoiceChat and type(C_VoiceChat.GetTtsVoices) == "function" then
		local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
		if ok and type(voices) == "table" then
			for _, candidate in ipairs(voices) do
				if type(candidate) == "table" and candidate.voiceID == voiceID then
					return candidate
				end
			end
		end
	end

	-- Last resort: TextToSpeech_Speak only ever dereferences .voiceID, so a
	-- minimal stand-in is honest here and still better than passing a number.
	return { voiceID = voiceID }
end

---The player's selected TTS voice as a TABLE, or nil when the route is
---unavailable or gives back something unusable.
---@return table|nil voice
local function ResolveVoice()
	if type(TextToSpeech_GetSelectedVoice) ~= "function" then return nil end

	local voiceType = Enum and Enum.TtsVoiceType and Enum.TtsVoiceType.Standard

	local ok, voice
	if voiceType ~= nil then
		ok, voice = pcall(TextToSpeech_GetSelectedVoice, voiceType)
	else
		-- The enum is gone but the function is not. Ask for the default rather
		-- than refusing outright.
		ok, voice = pcall(TextToSpeech_GetSelectedVoice)
	end
	if not ok then return nil end

	if type(voice) == "table" and type(voice.voiceID) == "number" then
		return voice
	end
	if type(voice) == "number" then
		return VoiceForID(voice)
	end

	return nil
end

---Speaks via the WeakAuras-style indirection. Returns false on any doubt, which
---is what lets the caller fall through to the sound.
---@param message string
---@return boolean spoken
local function SpeakTTS(message)
	if type(message) ~= "string" or message == "" then return false end
	if type(TextToSpeech_Speak) ~= "function" then return false end

	local voice = ResolveVoice()
	if not voice then return false end

	-- neverQueue = true: rule 2 above. We schedule; the engine must not also
	-- schedule, or a call we dropped as stale can still surface seconds later.
	local ok, err = pcall(TextToSpeech_Speak, message, voice, true, false)
	if not ok then
		PeaversCommons.Utils.Debug(PRT, "TTS route failed:", tostring(err))
		return false
	end

	return true
end

---Sound fallback. BigWigs/DBM/NSRT all reach for pre-recorded audio before TTS
---because it is the more proven path; until this addon ships its own OGGs, the
---built-in kit ids stand in.
---@param phase string "warn" | "call"
---@return boolean played
local function PlayFallbackSound(phase)
	if type(PlaySound) ~= "function" then return false end
	if type(SOUNDKIT) ~= "table" then return false end

	local soundID = phase == "warn"
		and SOUNDKIT.UI_RAID_BOSS_WHISPER_WARNING
		or SOUNDKIT.RAID_WARNING
	if type(soundID) ~= "number" then return false end

	return (pcall(PlaySound, soundID)) and true or false
end

---Both channels, in order, each independent of the other's failure.
---@param message string
---@param phase string
---@return boolean audible
local function Emit(message, phase)
	local spoke = false

	if PRT.Config.useTTS then
		spoke = SpeakTTS(message)
	end

	-- Deliberately not an `elseif`: TTS silently doing nothing is the common
	-- failure, and the sound is what stops that from being total silence.
	if not spoke and PRT.Config.soundFallback then
		spoke = PlayFallbackSound(phase)
	end

	return spoke
end

--------------------------------------------------------------------------------
-- Message building
--
-- Built at SPEAK time, never at queue time. A warning queued 4s out that drains
-- 2.5s later must say "in 2", not the "in 4" that was true when it was queued.
--------------------------------------------------------------------------------

---@param entry table timeline entry
---@param phase string "warn" | "call"
---@param clock number fight clock at the moment of speaking
---@return string|nil message nil when the message is no longer worth saying
local function BuildMessage(entry, phase, clock)
	local name = PRT.Spells:GetName(entry.spell)
	if phase ~= "warn" then
		return name
	end

	local remaining = entry.scheduled - clock

	-- The lead-in has already elapsed. Announcing "Barrier in 0" — or worse,
	-- announcing a warning after the cast was due — is the exact failure this
	-- module exists to avoid. The call is right behind it; let that speak.
	-- Reaching here at all should now be rare: DropStale applies the same bound.
	if remaining < WARN_SPEAK_FLOOR then return nil end

	return string.format("%s in %d", name, math.max(1, math.floor(remaining + 0.5)))
end

--------------------------------------------------------------------------------
-- Priority queue
--------------------------------------------------------------------------------

local function Now()
	return (type(GetTime) == "function" and GetTime()) or 0
end

---The live fight clock, or nil when nothing is running.
---@return number|nil clock
local function FightClock()
	local encounter = PRT.Encounter
	if not encounter or not encounter.active then return nil end
	local ok, clock = pcall(encounter.GetClock, encounter)
	if not ok or type(clock) ~= "number" then return nil end
	return clock
end

-- Calls outrank warnings, unconditionally. Everything queued as a "call" is due
-- now or overdue; everything queued as a "warn" is about a cast still ahead. When
-- the throttle can only afford one of them, the one about now wins.
local PHASE_RANK = { call = 1, warn = 2 }

---Sort predicate: urgency first, then the moment the item was due.
local function Precedes(a, b)
	local rankA = PHASE_RANK[a.phase] or 9
	local rankB = PHASE_RANK[b.phase] or 9
	if rankA ~= rankB then return rankA < rankB end
	return a.dueClock < b.dueClock
end

---Inserts in priority order.
local function Enqueue(item)
	local at = #queue + 1
	for i = 1, #queue do
		if Precedes(item, queue[i]) then
			at = i
			break
		end
	end
	table.insert(queue, at, item)
end

---The window a due cast is still worth calling in — the same one Timeline uses to
---decide a row has been MISSED, so the audio and the display agree on when a cast
---stopped being actionable.
---@return number seconds
local function ActiveWindow()
	local timeline = PRT.Encounter and PRT.Encounter.timeline
	local window = timeline and timeline.activeWindow
	if type(window) ~= "number" then return DEFAULT_ACTIVE_WINDOW end
	return window
end

---How many seconds past its due moment an item may still be spoken.
---
---This used to be one lead-in for both phases, which is where clustered casts got
---announced up to leadIn seconds late: with a 4s lead-in and a 1.5s throttle, a
---burst of three casts drained slowly enough that the last call landed a full 4s
---after the cast it was calling. It was inside the drop bound, so it was spoken —
---and "Barrier" spoken 4s after Barrier was due is the misleading-late
---announcement rule 3 exists to prevent.
---
---  call — worth saying while the cast is still worth making, and not one moment
---         longer. Past activeWindow the row has already gone red as missed;
---         calling for it then contradicts the screen.
---  warn — worth saying only while there is a countdown left to speak, so its
---         budget runs out WARN_SPEAK_FLOOR before the cast is due. Note a warn's
---         dueClock is already leadIn ahead of the cast, so this is a bound on
---         the warning's own lateness, not on the cast's.
---@param phase string
---@return number seconds
local function LatenessBudget(phase)
	if phase == "call" then
		return ActiveWindow()
	end
	return math.max((PRT.Config.leadInSeconds or 4) - WARN_SPEAK_FLOOR, 0)
end

---@param item table
---@param clock number
---@return boolean
local function IsStale(item, clock)
	return (clock - item.dueClock) > LatenessBudget(item.phase)
end

---Drops everything whose moment has passed beyond the point of being worth
---saying. An announcement that late describes a cast the player has already
---either made or missed, so saying it costs the next one its slot for nothing.
---@param clock number
local function DropStale(clock)
	for i = #queue, 1, -1 do
		if IsStale(queue[i], clock) then
			PeaversCommons.Utils.Debug(PRT, "dropped stale", queue[i].phase,
				string.format("%.1fs late", clock - queue[i].dueClock))
			table.remove(queue, i)
		end
	end
end

local function Drain()
	drainScheduled = false
	if #queue == 0 then return end

	local clock = FightClock()
	if not clock then
		-- The encounter ended under a queued item. Reset() normally clears this;
		-- this is the belt-and-braces path for anything that slipped through.
		queue = {}
		return
	end

	DropStale(clock)
	if #queue == 0 then return end

	local throttle = PRT.Config.announceThrottle or 1.5
	local waited = Now() - lastSpokenAt

	if waited < throttle then
		Announcer:ScheduleDrain(throttle - waited)
		return
	end

	local item = table.remove(queue, 1)
	local said = false
	if item then
		-- A guard, not a policy: an announcer that errors mid-pull is worse than
		-- a missed call, and the failure would otherwise be invisible.
		local ok, err = pcall(function()
			local message = BuildMessage(item.entry, item.phase, clock)
			if not message then
				PeaversCommons.Utils.Debug(PRT, "skipped", item.phase, "- no longer worth saying")
				return
			end

			local spoke = Emit(message, item.phase)
			lastSpokenAt = Now()
			said = true
			PeaversCommons.Utils.Debug(PRT, "announce", item.phase, message,
				spoke and "(audible)" or "(silent)")
		end)
		if not ok then
			PeaversCommons.Utils.Debug(PRT, "announce failed:", tostring(err))
		end
	end

	if #queue > 0 then
		-- Nothing was actually said, so nothing owes the throttle anything. Waiting
		-- a full interval after discarding an item would make dropping work SLOW
		-- the queue down — it is the item behind, which is by definition more
		-- urgent, that would pay for the silence that never happened.
		Announcer:ScheduleDrain(said and (PRT.Config.announceThrottle or 1.5) or 0)
	end
end

---@param delay number
function Announcer:ScheduleDrain(delay)
	if drainScheduled then return end
	if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
	drainScheduled = true
	C_Timer.After(math.max(delay, 0.05), Drain)
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

function Announcer:Initialize()
	self:Reset()
end

---Drops anything queued and clears the throttle. Called on every encounter
---start/stop so a wipe never spills the previous pull's calls into the next one.
function Announcer:Reset()
	queue = {}
	lastSpokenAt = 0
end

---Queues an announcement for one ghost cast.
---@param entry table timeline entry
---@param phase string "warn" | "call"
---@param clock number fight clock the event became due at
function Announcer:Announce(entry, phase, clock)
	if not PRT.Config.announceEnabled then return end
	if phase == "warn" and not PRT.Config.announceLeadIn then return end
	if type(entry) ~= "table" then return end

	if type(clock) ~= "number" then clock = FightClock() or 0 end

	local leadIn = PRT.Config.leadInSeconds or 4

	-- The moment this item WANTED to be spoken, in fight-clock seconds. Both the
	-- ordering and the staleness test key off this rather than off arrival time,
	-- so a backed-up queue degrades by dropping work instead of by sliding
	-- everything later and later.
	local dueClock = (phase == "warn") and (entry.scheduled - leadIn) or entry.scheduled

	local item = { entry = entry, phase = phase, dueClock = dueClock }

	-- Already too late at the moment of queuing — a hitch or a resumed replay
	-- jumped the clock straight past it. Literally the same predicate the drain
	-- applies, applied early so the item never takes a slot from something still
	-- useful.
	if IsStale(item, clock) then
		PeaversCommons.Utils.Debug(PRT, "not queuing stale", phase,
			string.format("%.1fs late", clock - dueClock))
		return
	end

	-- A call supersedes ITS OWN pending warning. Keyed on entry identity, not on
	-- spell id: a fight where the ghost casts the same spell twice would
	-- otherwise have the second cast's call delete the first cast's warning.
	for i = #queue, 1, -1 do
		local queued = queue[i]
		if queued.entry == entry and (queued.phase == phase or (queued.phase == "warn" and phase == "call")) then
			table.remove(queue, i)
		end
	end

	Enqueue(item)

	-- Scheduled, never drained inline. One tick can produce several events, and
	-- speaking the first one the instant it is queued would decide the batch by
	-- arrival order — which is exactly the priority the queue exists to override.
	-- Letting the whole batch land first costs at most the 0.05s floor below.
	self:ScheduleDrain(0)
end

---Speaks an arbitrary string through the same channels — used by the settings
---button to prove the audio route works without waiting for a pull.
---@param message string
---@return boolean spoken
function Announcer:Test(message)
	return Emit(message, "call")
end
