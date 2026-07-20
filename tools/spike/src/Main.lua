--[[ Main.lua
  PeaversRaidTimingsSpike — throwaway 12.0 (Midnight) viability diagnostic. NEVER SHIPPED.

  Staging step 0 of the PeaversRaidTimings ghost-replay plan. Its job is to answer the questions
  that independent API research could NOT settle, and to do it on a live client.

  THE FOUR OPEN QUESTIONS (this is what the spike leads with):

    (A) Does TextToSpeech_Speak ACTUALLY PRODUCE AUDIBLE SOUND from addon context?
        Called with the full documented signature
          TextToSpeech_Speak(text, voice, neverQueue, allowOverlappedSpeech)
        where `voice` is the TABLE returned by TextToSpeech_GetSelectedVoice(Enum.TtsVoiceType.Standard).
        A permitted pcall is NOT proof of audio. The addon therefore speaks a RANDOM word that it
        does not print, and the human must type back the word they heard. Only a matching word
        counts as PASS. Guessing is not possible, so "call permitted / silent" cannot be mistaken
        for success.

    (B) Does C_CombatAudioAlert.SpeakText error for tainted addon code? Its SecretArguments flag is
        "AllowedWhenUntainted", which is STRICTER than C_VoiceChat.SpeakText's AllowedWhenTainted,
        and addon code is tainted. The exact failure text is captured verbatim.

    (C) Does frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") raise
        ADDON_ACTION_FORBIDDEN on live 12.0+? A refused pcall is only half the question — the
        forbidden path fires an EVENT rather than erroring, so ADDON_ACTION_FORBIDDEN and
        ADDON_ACTION_BLOCKED are both captured and attributed. `/prtspike forbidden` runs a
        known-forbidden control (COMBAT_LOG_EVENT_UNFILTERED) to prove the detector itself works.
        The control provokes forbidden events NAMING THIS ADDON — that is what makes it a control,
        and those records are attributed to it and excluded from the verdict. Counting them as
        evidence against the API under test is how this verdict once came out backwards; see B8
        at RecordForbidden, and SelfTestForbidden which exists to keep it from coming back.

    (D) What does canaccessvalue ACTUALLY return for a genuinely secret value? Emulating this with
        metatables validates our logic against an ASSUMED behaviour, not the client's. So the
        oracle probes real candidate values — authored plain controls that must come back readable,
        and values annotated as secret by BigWigs — and reports the RAW returns of
        issecretvalue()/canaccessvalue() (type and printed form), not a coerced boolean.

  ROUTINE CHECK (no longer a headline verdict):
    UNIT_SPELLCAST_SUCCEEDED registered for unit "player" delivering a readable, comparable
    spellID is CONFIRMED by Blizzard's documentation. The check is kept because it costs nothing
    and guards against doc drift, but it is reported as a routine check, not as the gate that
    decides whether the product is buildable.

  Design rules this file obeys, because it runs inside a live raid pull:
    - Never error out mid-encounter. Every probe and every API call is pcall-wrapped; a blocked
      or missing API degrades to a recorded "blocked" string, never to a Lua error.
    - Never touch a value before proving it is safe. issecretvalue()/canaccessvalue() are asked
      FIRST; type()/tostring() are only reached when ProbeReadable() says the value is touchable.
    - ONE definition of "readable", ProbeReadable(), used by the touch gate, the counters and
      every verdict. Two definitions is how the old build reported FAIL on a perfectly readable
      number and PARTIAL on a value it had just printed as SECRET.
    - "The probe APIs are absent" is INCONCLUSIVE, never a definite verdict in either direction.
    - Never put a raw probed value into SavedVariables. Everything persisted is a string, number
      or boolean produced by Probe(). Serialising a secret value would break the save file.
    - Every run carries an identity and SaveRun() replaces in place, so calling /prtspike
      repeatedly mid-fight cannot flood the history with duplicates of one run.
    - No PeaversCommons dependency. Standalone on purpose — fewer moving parts, and a framework
      bug must not be able to masquerade as a client-capability finding.

  APIs resolved through _G rather than referenced directly: C_CombatAudioAlert, C_EncounterTimeline,
  C_UnitAuras, TextToSpeech_Speak, TextToSpeech_GetSelectedVoice, canaccessvalue, UnitCastingInfo,
  UnitClassification. All of these are present in the 120007 /papidump but ABSENT from wow-api's
  curated global floor, so a direct reference would false-positive degraded-mode lint — and a _G
  lookup is the more defensive form anyway, since a missing API is one of the outcomes measured.
]]

local addonName = ...

local TAG      = "|cff3abdf7Peavers|rRTSpike: "
local C_GOOD   = "|cff44ff44"
local C_BAD    = "|cffff5555"
local C_WARN   = "|cffffcc00"
local C_DIM    = "|cff999999"
local C_OFF    = "|r"

local MAX_RUNS          = 10   -- keep the save file small; oldest run is dropped
local MAX_CAST_SAMPLES  = 40   -- per run; a pull produces hundreds, 40 proves the point
local MAX_TIMELINE      = 8    -- encounter-timeline events sampled per probe
local MAX_FORBIDDEN     = 40   -- ADDON_ACTION_* records kept per run

-- 2 added run identity. 3 added forbidden-record provenance (seq/fromControl): without it a
-- record provoked by the detector control is indistinguishable from a genuine one, which is the
-- exact confusion B8 was. Older saves are discarded rather than migrated — a run whose records
-- cannot be attributed cannot be scored, and scoring it anyway is how (C) came out backwards.
local DB_SCHEMA = 3

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

local function Say(msg)
  print(TAG .. tostring(msg))
end

local function SayRaw(msg)
  print(tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Secret-value probing
--
-- The ONLY safe order of operations on 12.0. issecretvalue()/canaccessvalue() are themselves
-- designed to accept a secret value as an argument, so asking them first is legal; type() and
-- tostring() are not, so they are gated behind a positive safety answer. Both gate functions
-- are also pcall'd, because on a client where they do not exist or have changed arity, this
-- addon must still produce a report rather than an error.
-- ---------------------------------------------------------------------------

local isSecretFn  = (type(issecretvalue) == "function") and issecretvalue or nil
local canAccessFn = (type(_G["canaccessvalue"]) == "function") and _G["canaccessvalue"] or nil

-- Question (D) wants the RAW return of the gate functions, not a coerced boolean. The gate
-- functions are contracted to return a plain boolean; if that contract is wrong, this describer
-- is exactly what catches it, so it is pcall'd like everything else.
local function RawDesc(v)
  local okT, t = pcall(type, v)
  local okS, s = pcall(tostring, v)
  return string.format("%s(%s)", okT and tostring(t) or "<type() blocked>",
                                 okS and tostring(s) or "<tostring() blocked>")
end

-- THE single definition of "readable", used by the touch gate, the counters and every verdict.
--
-- issecretvalue() is asked FIRST and is decisive when it says false, because the two functions do
-- not describe the same thing. The documented wording is:
--   issecretvalue(value)   -> true if the supplied VALUE is secret
--   canaccessvalue(value)  -> true if the CALLING FUNCTION has permission to operate on secret values
-- The second is a property of the caller, not of the value. Tainted addon code may therefore get
-- accessible=false for a perfectly ordinary number, which is why canaccessvalue can only ADD
-- readability, never remove it. Confirming that reading on a live client is question (D).
local function ProbeReadable(d)
  if type(d) ~= "table" then return false end
  return (d.secret == false) or (d.accessible == true and d.secret ~= true)
end

-- Did the client actually answer? Neither gate returning a boolean means the probe APIs are
-- unavailable on this client, and NOTHING about secrecy may be concluded in either direction.
local function ProbeConclusive(d)
  if type(d) ~= "table" then return false end
  return type(d.secret) == "boolean" or type(d.accessible) == "boolean"
end

-- Probe(v) -> descriptor table of plain strings/booleans. Safe to persist, safe to print.
local function Probe(v)
  local d = {}

  if isSecretFn then
    local ok, res = pcall(isSecretFn, v)
    if ok then
      d.secret = res and true or false
      d.secretRaw = RawDesc(res)
    else
      d.secret = "probe-errored: " .. tostring(res)
      d.secretRaw = "<issecretvalue errored>"
    end
  else
    d.secret = "issecretvalue-missing"
    d.secretRaw = "<api missing>"
  end

  if canAccessFn then
    local ok, res = pcall(canAccessFn, v)
    if ok then
      d.accessible = res and true or false
      d.accessibleRaw = RawDesc(res)
    else
      d.accessible = "probe-errored: " .. tostring(res)
      d.accessibleRaw = "<canaccessvalue errored>"
    end
  else
    d.accessible = "canaccessvalue-missing"
    d.accessibleRaw = "<api missing>"
  end

  d.conclusive = ProbeConclusive(d)

  -- Recorded for (D), NOT treated as an error. Under the documented reading the two gates answer
  -- different questions, so secret=false + accessible=false is the EXPECTED shape for tainted
  -- addon code looking at an ordinary value. Flagging it makes that visible in the raw dump
  -- instead of leaving the reader to infer it.
  d.gatesDisagree = (d.secret == false and d.accessible == false)
                 or (d.secret == true and d.accessible == true)

  -- Only touch the value on positive evidence that touching it is safe.
  if not ProbeReadable(d) then
    d.type = "<not touched>"
    d.value = "<not touched: secret, inaccessible, or unprobeable>"
    return d
  end

  local okT, t = pcall(type, v)
  d.type = okT and t or ("type() blocked: " .. tostring(t))

  local okS, s = pcall(tostring, v)
  d.value = okS and tostring(s) or ("tostring() blocked: " .. tostring(s))

  return d
end

-- One-line human summary of a descriptor.
local function Fmt(d)
  if type(d) ~= "table" then return C_DIM .. "<no probe>" .. C_OFF end
  local flag
  if not ProbeConclusive(d) then
    flag = C_WARN .. "UNPROBEABLE" .. C_OFF
  elseif ProbeReadable(d) then
    flag = C_GOOD .. "readable" .. C_OFF
  else
    flag = C_BAD .. "SECRET" .. C_OFF
  end
  return string.format("%s  secret=%s  access=%s  type=%s  value=%s",
    flag, tostring(d.secret), tostring(d.accessible), tostring(d.type), tostring(d.value))
end

-- The (D) view: the same descriptor, but showing what the gate functions literally returned.
local function FmtRaw(d)
  if type(d) ~= "table" then return C_DIM .. "<no probe>" .. C_OFF end
  return string.format("issecretvalue->%s  canaccessvalue->%s%s",
    tostring(d.secretRaw), tostring(d.accessibleRaw),
    d.gatesDisagree and ("  " .. C_DIM .. "[gates differ]" .. C_OFF) or "")
end

-- Try(fn) -> { ok = bool, result | err = string }. Used for the comparability tests, where the
-- interesting outcome is frequently the error text rather than a returned value.
local function Try(fn)
  local ok, res = pcall(fn)
  if not ok then return { ok = false, err = tostring(res) } end
  local okS, s = pcall(tostring, res)
  return { ok = true, result = okS and tostring(s) or "<result unprintable>" }
end

local function FmtTry(t)
  if type(t) ~= "table" then return C_DIM .. "<not run>" .. C_OFF end
  if t.ok then return C_GOOD .. "ok" .. C_OFF .. " -> " .. tostring(t.result) end
  return C_BAD .. "FAILED" .. C_OFF .. " -> " .. tostring(t.err)
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- Run identity. Every run gets an id unique within this login, so SaveRun() can replace the
-- record it already wrote instead of appending a second copy of the same run.
local SESSION_ID = date("%Y%m%d-%H%M%S")
local runSeq = 0

local run = nil          -- the in-progress run record, or nil outside an encounter
local session = {        -- cross-encounter tallies for the current login
  castEvents = 0,
  castReadable = 0,
  castComparable = 0,
}

local function NewRun(kind)
  runSeq = runSeq + 1
  return {
    id          = SESSION_ID .. "#" .. tostring(runSeq),
    kind        = kind,
    startedAt   = date("%Y-%m-%d %H:%M:%S"),
    encounter   = nil,
    unitRegistrationDuringEncounter = nil,
    casts       = {},
    castTotals  = { seen = 0, readable = 0, comparable = 0, unprobeable = 0 },
    bossUnits   = {},
    timeline    = {},
    oracle      = nil,
    forbidden   = {},
    -- Monotonic and UNCAPPED, unlike #forbidden. The control scores itself by counting records,
    -- and r.forbidden stops growing at MAX_FORBIDDEN — so a busy pull could make a control that
    -- DID fire look like it had not, downgrading (C) to INCONCLUSIVE for no reason.
    forbiddenSeen = 0,
    tts         = {},
    notes       = {},
  }
end

local function Note(msg)
  if run then run.notes[#run.notes + 1] = tostring(msg) end
end

local function EnsureRun()
  if not run then run = NewRun("manual") end
  return run
end

-- ---------------------------------------------------------------------------
-- (A) + (B) TTS
--
-- CRITICAL READING NOTE: neither API returns "audio was produced". A pcall that returns ok
-- proves only that the CALL was permitted — not that anything was audible.
--
-- So the spike does not ask "did you hear something?", which invites a polite yes. It speaks a
-- word chosen at random from a list and DOES NOT PRINT IT. The human types back what they heard
-- with `/prtspike heard <word>`, and only an exact match is scored as audible. Each path gets a
-- different word, spoken three seconds apart, so the two paths cannot be confused for each other.
-- ---------------------------------------------------------------------------

local TTS_WORDS = {
  "elephant", "harpoon", "cinnamon", "trombone", "avalanche",
  "marigold", "pumpkin", "obsidian", "cathedral", "lantern",
  "walnut", "flamingo", "zeppelin", "porridge", "kettledrum",
}

do
  local seed = 1
  local okTime, t = pcall(GetTime)
  if okTime and type(t) == "number" then seed = math.floor(t * 1000) % 2147483647 end
  pcall(math.randomseed, seed)
end

local function PickWords()
  local a = math.random(#TTS_WORDS)
  local b = a
  while b == a do b = math.random(#TTS_WORDS) end
  return TTS_WORDS[a], TTS_WORDS[b]
end

-- Blizzard's TextToSpeech_Speak ends in
--   C_VoiceChat.SpeakText(voice.voiceID, text, C_TTSSettings.GetSpeechRate(),
--                         C_TTSSettings.GetSpeechVolume(), allowOverlappedSpeech)
-- so a speech volume of 0 produces a permitted, entirely silent call. Capturing the settings is
-- what separates "TTS is blocked for addons" from "your volume slider is down" — two findings
-- that look identical from the call site and mean completely different things for the product.
local function TtsSettingsSnapshot()
  local s = {}
  local settings = _G["C_TTSSettings"]
  local voiceChat = _G["C_VoiceChat"]
  s.rate   = settings and FmtTry(Try(function() return settings.GetSpeechRate() end)) or "<C_TTSSettings missing>"
  s.volume = settings and FmtTry(Try(function() return settings.GetSpeechVolume() end)) or "<C_TTSSettings missing>"
  s.voiceCount = voiceChat and FmtTry(Try(function()
    local v = voiceChat.GetTtsVoices()
    return type(v) == "table" and #v or ("returned " .. type(v))
  end)) or "<C_VoiceChat missing>"

  -- Numeric copies, because the (A) verdict has to ACT on these rather than print them and hope
  -- the reader notices. A speech volume of 0, or no installed voices, makes a permitted call
  -- silent for reasons that have nothing to do with addon permissions — reporting that as
  -- "FAIL: TTS is silent for addons" would kill the product over a slider position.
  if settings then
    local okV, v = pcall(settings.GetSpeechVolume)
    if okV and type(v) == "number" then s.volumeNum = v end
  end
  if voiceChat then
    local okL, list = pcall(voiceChat.GetTtsVoices)
    if okL and type(list) == "table" then s.voiceCountNum = #list end
  end
  return s
end

-- Path A — the WeakAuras indirection, called with the FULL documented signature.
--
-- The two trailing booleans are not decoration. In Blizzard's implementation
--   shouldQueue = (playbackActive or uiHidden) and not neverQueue
-- and a queued utterance returns EARLY without speaking. neverQueue=true would instead drop the
-- utterance outright whenever something else is mid-speech. Either way the call returns ok and
-- nothing is heard, which is precisely the false negative this question must not produce — so
-- this passes neverQueue=false and reports queueing conditions rather than guessing.
-- allowOverlappedSpeech=false keeps A and B from colliding if 3s is not enough on a slow voice.
local function TtsWeakAuras(message)
  local getVoice = _G["TextToSpeech_GetSelectedVoice"]
  local speak    = _G["TextToSpeech_Speak"]

  if type(getVoice) ~= "function" then
    return { path = "TextToSpeech_Speak", ok = false, err = "TextToSpeech_GetSelectedVoice does not exist" }
  end
  if type(speak) ~= "function" then
    return { path = "TextToSpeech_Speak", ok = false, err = "TextToSpeech_Speak does not exist" }
  end

  local voiceType = Enum and Enum.TtsVoiceType and Enum.TtsVoiceType.Standard
  if voiceType == nil then
    return { path = "TextToSpeech_Speak", ok = false,
             err = "Enum.TtsVoiceType.Standard does not exist" }
  end

  local okV, voice = pcall(getVoice, voiceType)
  if not okV then
    return { path = "TextToSpeech_Speak", ok = false, err = "GetSelectedVoice errored: " .. tostring(voice) }
  end
  if not voice then
    return { path = "TextToSpeech_Speak", ok = false,
             err = "GetSelectedVoice returned nil (no voice configured on this client)" }
  end

  local voiceProbe = Probe(voice)
  -- The contract is a TABLE ({ voiceID, name, ... }) and the implementation indexes voice.voiceID,
  -- so a non-table here means the call errors rather than going silent. Recorded either way,
  -- because "we passed the wrong thing" must never be reported as "the client blocked us".
  local voiceShape = tostring(voiceProbe.type)
  local voiceID = "<not read>"
  if voiceShape == "table" then
    local okID, id = pcall(function() return voice.voiceID end)
    voiceID = okID and tostring(id) or ("read errored: " .. tostring(id))
  end

  local neverQueue, allowOverlappedSpeech = false, false
  local ok, err = pcall(speak, message, voice, neverQueue, allowOverlappedSpeech)
  return {
    path = "TextToSpeech_Speak",
    signature = "TextToSpeech_Speak(text, voice, neverQueue=false, allowOverlappedSpeech=false)",
    ok = ok and true or false,
    err = (not ok) and tostring(err) or nil,
    voice = voiceProbe,
    voiceShape = voiceShape,
    voiceID = voiceID,
    settings = TtsSettingsSnapshot(),
    spoke = message,
    caveat = "call-level result only; audibility is decided by /prtspike heard <word>",
  }
end

-- Path B — the purpose-built API. Flagged SecretArguments = "AllowedWhenUntainted", which is
-- STRICTER than C_VoiceChat.SpeakText's AllowedWhenTainted. Addon code is tainted, so this may
-- be uncallable by us at all. Capturing the exact failure either way is question (B).
local function TtsCombatAudioAlert(message)
  local api = _G["C_CombatAudioAlert"]
  -- `outcome` exists because ok=false has FOUR distinct causes and only one of them answers (B).
  -- "the API is not on this client" is not "it errored for tainted code", and reporting it as
  -- such is absence of evidence dressed up as a definite finding.
  if type(api) ~= "table" then
    return { path = "C_CombatAudioAlert.SpeakText", ok = false, outcome = "api-absent",
             err = "C_CombatAudioAlert does not exist" }
  end
  if type(api.SpeakText) ~= "function" then
    return { path = "C_CombatAudioAlert.SpeakText", ok = false, outcome = "api-absent",
             err = "C_CombatAudioAlert.SpeakText does not exist" }
  end

  local enabled = Try(function() return api.IsEnabled and api.IsEnabled() end)

  -- Category enum name is not in the curated floor and may differ; fall back to a plain 0. If we
  -- had to fall back, an error can no longer be attributed — a rejected argument and a taint
  -- refusal look identical from here — so the verdict degrades to INCONCLUSIVE rather than
  -- crediting the client with a block it may not have made.
  local enumValue = Enum and Enum.CombatAudioAlertCategory and Enum.CombatAudioAlertCategory.Generic
  local category = enumValue or 0
  local ok, err = pcall(api.SpeakText, message, category, true)
  return {
    path = "C_CombatAudioAlert.SpeakText",
    ok = ok and true or false,
    outcome = ok and "permitted" or "call-errored",
    categoryFallback = (enumValue == nil),
    err = (not ok) and tostring(err) or nil,
    isEnabled = FmtTry(enabled),
    categoryUsed = tostring(category),
    spoke = message,
    caveat = "call-level result only; audibility is decided by /prtspike heard <word>",
  }
end

local function RunTtsProbes(reason)
  local r = EnsureRun()
  local wordA, wordB = PickWords()

  -- Running /prtspike tts twice replaces the word pair, but the FIRST pair may still be in the
  -- air (queued utterances speak late). A human reporting the older word would otherwise be
  -- scored as "matches neither word", which reads as evidence the client spoke something wrong.
  -- Retired pairs are kept so that report can be named for what it is.
  r.ttsRetiredWords = r.ttsRetiredWords or {}
  if type(r.tts) == "table" and type(r.tts.words) == "table" then
    r.ttsRetiredWords[#r.ttsRetiredWords + 1] = r.tts.words.a
    r.ttsRetiredWords[#r.ttsRetiredWords + 1] = r.tts.words.b
  end

  r.tts = {
    reason = reason,
    words = { a = wordA, b = wordB },
    confirmed = { a = nil, b = nil },
    reports = {},
    askedAt = date("%Y-%m-%d %H:%M:%S"),
  }

  r.tts.a = TtsWeakAuras("Path A. The word is " .. wordA .. ". Again, " .. wordA .. ".")
  Say("TTS path A (TextToSpeech_Speak): " ..
      (r.tts.a.ok and (C_GOOD .. "call permitted" .. C_OFF) or (C_BAD .. "blocked" .. C_OFF .. " — " .. tostring(r.tts.a.err))))
  if r.tts.a.ok then
    Say("  voice shape: " .. tostring(r.tts.a.voiceShape) .. "  voiceID: " .. tostring(r.tts.a.voiceID))
  end

  -- Separated so the two sentences cannot overlap and be mistaken for one another. `r` is
  -- captured, not re-read: a wipe mid-encounter must not file path B under a different run.
  C_Timer.After(3, function()
    local ok, res = pcall(TtsCombatAudioAlert, "Path B. The word is " .. wordB .. ". Again, " .. wordB .. ".")
    r.tts.b = ok and res or { path = "C_CombatAudioAlert.SpeakText", ok = false,
                              outcome = "probe-errored",
                              err = "probe itself errored: " .. tostring(res) }
    Say("TTS path B (C_CombatAudioAlert.SpeakText): " ..
        (r.tts.b.ok and (C_GOOD .. "call permitted" .. C_OFF) or (C_BAD .. "blocked" .. C_OFF .. " — " .. tostring(r.tts.b.err))))
    SayRaw(" ")
    Say(C_WARN .. "Each path spoke a DIFFERENT random word. The words are not printed." .. C_OFF)
    Say(C_WARN .. "Type what you heard:  /prtspike heard <word>   (or  /prtspike heard nothing )" .. C_OFF)
  end)
end

-- Record a human audibility report. Only an exact word match counts.
local function RecordHeard(text)
  local r = EnsureRun()
  local said = string.lower(strtrim(tostring(text or "")))
  if said == "" then
    Say(C_WARN .. "usage: /prtspike heard <word>   (or  /prtspike heard nothing )" .. C_OFF)
    return
  end
  if type(r.tts) ~= "table" or type(r.tts.words) ~= "table" then
    Say(C_WARN .. "no TTS probe has been run in this run yet — /prtspike tts first." .. C_OFF)
    return
  end

  r.tts.reports[#r.tts.reports + 1] = said

  if said == "nothing" or said == "neither" or said == "silence" then
    -- Only a path whose CALL was permitted can be scored silent. Recording "you heard nothing"
    -- against a path that never got to speak (API absent, call refused) would manufacture an
    -- audibility finding out of a permission finding.
    if type(r.tts.a) == "table" and r.tts.a.ok then r.tts.confirmed.a = false end
    if type(r.tts.b) == "table" and r.tts.b.ok then r.tts.confirmed.b = false end
    Say(C_BAD .. "recorded: NO AUDIO from either path that was permitted to speak." .. C_OFF ..
        " (A said \"" .. tostring(r.tts.words.a) .. "\", B said \"" .. tostring(r.tts.words.b) .. "\")")
  elseif said == r.tts.words.a then
    r.tts.confirmed.a = true
    Say(C_GOOD .. "MATCH — path A (TextToSpeech_Speak) produced AUDIBLE sound." .. C_OFF)
  elseif said == r.tts.words.b then
    r.tts.confirmed.b = true
    Say(C_GOOD .. "MATCH — path B (C_CombatAudioAlert.SpeakText) produced AUDIBLE sound." .. C_OFF)
  else
    local stale = false
    for _, w in ipairs(r.ttsRetiredWords or {}) do
      if said == w then stale = true break end
    end
    if stale then
      Say(C_WARN .. "\"" .. said .. "\" is from an EARLIER /prtspike tts, not the current one. " ..
          "Not scored — a late queued utterance is not evidence about this probe. Re-run " ..
          "/prtspike tts and report the new word." .. C_OFF)
    else
      Say(C_WARN .. "\"" .. said .. "\" matches neither word. Recorded as a mismatch — " ..
          "either you misheard, or the client spoke something else." .. C_OFF)
    end
  end
  Say(C_DIM .. "heard the other one too? run /prtspike heard <word> again." .. C_OFF)
end

-- ---------------------------------------------------------------------------
-- (C) ADDON_ACTION_FORBIDDEN / ADDON_ACTION_BLOCKED capture
--
-- The forbidden path does not error at the call site — it fires an event naming the addon and the
-- function. A pcall around RegisterUnitEvent therefore proves nothing on its own, which is why
-- the old build's "registration ok" was not an answer to (C).
-- ---------------------------------------------------------------------------

-- Registration outcomes happen once, at load, before any run exists.
local registration = {}

-- B8, the verdict-inverting bug. RunForbiddenControl DELIBERATELY provokes ADDON_ACTION_FORBIDDEN
-- naming THIS addon — that is what makes it a control. Those records were then counted as evidence
-- AGAINST the API under test, so following the README verbatim printed "detector works" directly
-- above "VERDICT (C): FAIL" on the one detection channel the whole product depends on.
--
-- A record provoked by the control is now attributed to it by THREE independent guards, because
-- any single one can be defeated:
--   1. an explicit window flag, set around the control's registration call,
--   2. the monotonic record-index range the control spanned (recordsBefore+1 .. recordsAfter),
--   3. the set of func names seen while that window was open.
-- Only records that survive all three count as evidence about (C).
local forbiddenControlWindow = nil   -- { funcs = {} } while the control is in flight

-- Is this func name the API question (C) is actually about? A forbidden naming us for something
-- else is a real finding, but it is NOT an answer to "is RegisterUnitEvent forbidden" and must not
-- be scored as one in either direction.
local function IsProductSurface(func)
  local f = string.lower(tostring(func))
  return (string.find(f, "registerunitevent", 1, true) ~= nil)
      or (string.find(f, "unit_spellcast", 1, true) ~= nil)
end

local function RecordForbidden(event, blockedAddon, blockedFunc)
  local r = EnsureRun()
  r.forbiddenSeen = (r.forbiddenSeen or 0) + 1

  local func = tostring(blockedFunc)
  -- Tag at CAPTURE time. Reconstructing provenance afterwards is what B8 got wrong.
  local window = forbiddenControlWindow
  local fromControl = (window ~= nil)
  if window then window.funcs[func] = true end

  local rec = {
    seq   = r.forbiddenSeen,
    event = tostring(event),
    addon = tostring(blockedAddon),
    func  = func,
    at    = date("%H:%M:%S"),
    ours  = (tostring(blockedAddon) == tostring(addonName)),
    fromControl = fromControl,
  }
  if #r.forbidden < MAX_FORBIDDEN then r.forbidden[#r.forbidden + 1] = rec end
  if rec.ours then
    Say(C_BAD .. rec.event .. C_OFF .. " named THIS addon: " .. func ..
        (fromControl and ("  " .. C_DIM .. "(expected — provoked by the detector control)" .. C_OFF)
                      or ""))
  end
  return rec
end

-- Split a run's forbidden records into the four things they can be. Pure, so the self-test can
-- drive it with synthetic runs.
local function ClassifyForbidden(r)
  local out = { control = {}, relevant = {}, unattributed = {}, other = 0 }
  local ctl = type(r) == "table" and r.forbiddenControl or nil

  local lo, hi
  -- Both bounds required. recordsAfter is nil while the control is still in flight, and an open
  -- upper bound would swallow every later record — including genuine ones.
  if ctl and ctl.recordsBefore and ctl.recordsAfter then
    lo, hi = ctl.recordsBefore + 1, ctl.recordsAfter
  end
  local ctlFuncs = (ctl and ctl.funcs) or {}

  for _, f in ipairs((type(r) == "table" and r.forbidden) or {}) do
    if not f.ours then
      out.other = out.other + 1
    else
      local seq = tonumber(f.seq)
      local inWindow = (lo ~= nil and seq ~= nil and seq >= lo and seq <= hi)
      if f.fromControl or inWindow or ctlFuncs[tostring(f.func)] then
        out.control[#out.control + 1] = f
      elseif IsProductSurface(f.func) then
        out.relevant[#out.relevant + 1] = f
      else
        out.unattributed[#out.unattributed + 1] = f
      end
    end
  end
  return out
end

-- The (C) verdict, as a pure function of the run and the load-time registration outcome.
-- Extracted so SelfTestForbidden can prove, without a client, that the control cannot fabricate
-- a FAIL. Returns code ("PASS" | "FAIL" | "INCONCLUSIVE") and human text.
--
-- ctl.detectorWorks is consulted BEFORE any record count, so "we have records" can never outrank
-- "those records are the control's own". The one exception is deliberate: a forbidden event that
-- we did NOT provoke is itself proof the detector fires, so it also satisfies detectorProven —
-- otherwise a genuine failure observed without running the control would be softened to
-- INCONCLUSIVE, which is the same class of wrong verdict in the opposite direction.
local function ForbiddenVerdict(r, reg)
  local c = ClassifyForbidden(r)
  local ctl = type(r) == "table" and r.forbiddenControl or nil
  local detectorProven = (ctl ~= nil and ctl.detectorWorks == true)
                      or #c.relevant > 0 or #c.unattributed > 0

  if not (reg and reg.castOk) then
    return "FAIL", "FAIL — the register call itself was refused: " ..
                   tostring(reg and reg.castErr or "no registration record")
  end
  if not detectorProven then
    if not ctl then
      return "INCONCLUSIVE", "INCONCLUSIVE — nothing named this addon, but the detector is " ..
             "unproven, so silence proves nothing. Run /prtspike forbidden."
    elseif ctl.detectorWorks == nil then
      return "INCONCLUSIVE", "INCONCLUSIVE — the detector control is still in flight. " ..
             "Re-run /prtspike in a few seconds."
    end
    return "INCONCLUSIVE", "INCONCLUSIVE — the known-forbidden control did NOT trip the detector, " ..
           "so the absence of forbidden events is not evidence."
  end
  if #c.relevant > 0 then
    return "FAIL", "FAIL — ADDON_ACTION_FORBIDDEN/BLOCKED named this addon for the API under " ..
                   "test (" .. tostring(c.relevant[1].func) .. ")."
  end
  if #c.unattributed > 0 then
    return "INCONCLUSIVE", "INCONCLUSIVE — forbidden events named this addon, but for funcs " ..
           "unrelated to RegisterUnitEvent (" .. tostring(c.unattributed[1].func) .. "). " ..
           "Not an answer to (C) in either direction."
  end
  return "PASS", "PASS — detector proven live, and it never named this addon outside the control."
end

-- Self-test for B8: the control path must not be able to produce a FAIL, and the guards must not
-- have overshot into hiding a genuine failure. Runs on synthetic records, so it needs no client.
local function SelfTestForbidden()
  local results = {}
  local function check(name, cond, detail)
    results[#results + 1] = { name = name, ok = cond and true or false, detail = tostring(detail) }
  end
  local reg = { castOk = true }

  local function ctlRec(seq, flagged, func)
    return { seq = seq, ours = true, fromControl = flagged, func = func,
             event = "ADDON_ACTION_FORBIDDEN", at = "00:00:00" }
  end

  -- 1. All three guards present: the control fired and every record is its own.
  local code = ForbiddenVerdict({
    forbiddenSeen = 2,
    forbidden = { ctlRec(1, true, "RegisterEvent()"), ctlRec(2, true, "RegisterEvent()") },
    forbiddenControl = { recordsBefore = 0, recordsAfter = 2, detectorWorks = true,
                         funcs = { ["RegisterEvent()"] = true } },
  }, reg)
  check("control records with all guards do not FAIL", code ~= "FAIL", code)
  check("control records with all guards read PASS", code == "PASS", code)

  -- 2. Flag and func set stripped — index-window attribution alone must still hold.
  code = ForbiddenVerdict({
    forbiddenSeen = 1,
    forbidden = { ctlRec(1, false, "RegisterEvent()") },
    forbiddenControl = { recordsBefore = 0, recordsAfter = 1, detectorWorks = true, funcs = {} },
  }, reg)
  check("window attribution alone does not FAIL", code ~= "FAIL", code)

  -- 3. Flag and window stripped — func attribution alone must still hold.
  code = ForbiddenVerdict({
    forbiddenSeen = 1,
    forbidden = { ctlRec(1, false, "RegisterEvent()") },
    forbiddenControl = { detectorWorks = true, funcs = { ["RegisterEvent()"] = true } },
  }, reg)
  check("func attribution alone does not FAIL", code ~= "FAIL", code)

  -- 4. The guards must NOT swallow a genuine failure on the API under test.
  code = ForbiddenVerdict({
    forbiddenSeen = 2,
    forbidden = { ctlRec(1, true, "RegisterEvent()"),
                  { seq = 2, ours = true, fromControl = false, func = "RegisterUnitEvent()",
                    event = "ADDON_ACTION_FORBIDDEN", at = "00:00:00" } },
    forbiddenControl = { recordsBefore = 0, recordsAfter = 1, detectorWorks = true,
                         funcs = { ["RegisterEvent()"] = true } },
  }, reg)
  check("genuine RegisterUnitEvent forbidden still FAILs", code == "FAIL", code)

  -- 5. A refused register call is direct evidence and outranks everything.
  code = ForbiddenVerdict({ forbidden = {} }, { castOk = false, castErr = "refused" })
  check("refused registration FAILs", code == "FAIL", code)

  -- 6. Absence of evidence, with no control run, is never a definite verdict.
  code = ForbiddenVerdict({ forbidden = {} }, reg)
  check("no control run is INCONCLUSIVE", code == "INCONCLUSIVE", code)

  -- 7. Control ran and did not fire: silence still proves nothing.
  code = ForbiddenVerdict({
    forbidden = {},
    forbiddenControl = { recordsBefore = 0, recordsAfter = 0, detectorWorks = false, funcs = {} },
  }, reg)
  check("control that did not fire is INCONCLUSIVE", code == "INCONCLUSIVE", code)

  -- 8. Control still in flight is pending, not a verdict.
  code = ForbiddenVerdict({
    forbidden = {},
    forbiddenControl = { recordsBefore = 0, funcs = {} },
  }, reg)
  check("control in flight is INCONCLUSIVE", code == "INCONCLUSIVE", code)

  local failed = 0
  for _, res in ipairs(results) do if not res.ok then failed = failed + 1 end end
  return results, failed
end

-- ---------------------------------------------------------------------------
-- Routine check: comparability battery
--
-- "Readable" is not enough. The product needs the spellID as a TABLE KEY (cue lookup) and in
-- == comparisons (did the player press the cued spell?). A value can in principle be readable
-- for tostring and still unusable for either, so each capability is tested independently.
-- ---------------------------------------------------------------------------

local function Comparability(spellID)
  local r = {}

  r.selfEquality  = Try(function() return spellID == spellID end)
  r.litEquality   = Try(function() return spellID == 47788 end)      -- arbitrary real spell id
  r.tonumber      = Try(function() return tonumber(spellID) end)
  r.arithmetic    = Try(function() return spellID + 0 end)
  r.stringFormat  = Try(function() return string.format("%s", spellID) end)
  r.tableKey      = Try(function()
    local t = {}
    t[spellID] = "hit"
    return t[spellID]
  end)
  -- The realistic product shape: our own authored plain-number key looked up by the event value.
  r.lookupOurTable = Try(function()
    local cues = { [47788] = "Guardian Spirit", [740] = "Tranquility" }
    return cues[spellID] or "no-match(but-lookup-succeeded)"
  end)

  return r
end

-- A comparability result set passes only if every capability the product actually needs works.
--
-- READABILITY IS A PRECONDITION, NOT A FOURTH AXIS. A secret value passes the mechanical tests
-- by object identity: `t[v] = x; t[v]` round-trips because tables hash by identity, and `v == v`
-- is true for the same reference. Neither means the value can be matched against the plain
-- numeric cue tables we author, which is the only thing the product actually needs. Scoring the
-- battery alone reports PASS on a fully secret spellID, so readability is checked first and hard
-- — using ProbeReadable(), the same definition the counters and the verdict use.
--
-- Nor is `litEquality` / `lookupOurTable` returning *false* a failure: the player is usually
-- casting something other than our arbitrary sample id. Those two are informational. The tests
-- that genuinely discriminate are the numeric ones — a real spellID is a number, converts, and
-- does arithmetic.
local function ComparabilityPassed(probe, r)
  if type(probe) ~= "table" or type(r) ~= "table" then return false end

  if not ProbeReadable(probe) then return false end
  if probe.type ~= "number" then return false end

  return (r.tonumber and r.tonumber.ok and r.tonumber.result ~= "nil")
     and (r.arithmetic and r.arithmetic.ok)
     and (r.tableKey and r.tableKey.ok and r.tableKey.result == "hit")
     and (r.selfEquality and r.selfEquality.ok and r.selfEquality.result == "true")
end

-- ---------------------------------------------------------------------------
-- (D) Secret-value oracle
--
-- Probes real candidate values and reports the RAW gate returns. The controls are the point: an
-- authored plain number MUST come back readable. If a control reports SECRET, the probe APIs are
-- lying (or we are calling them wrong) and every other secrecy finding in this report is void.
-- ---------------------------------------------------------------------------

local function OracleCandidates()
  local out = {}

  local function add(label, expectation, fn)
    local ok, v = pcall(fn)
    if not ok then
      out[#out + 1] = { label = label, expectation = expectation, unavailable = tostring(v) }
      return
    end
    out[#out + 1] = { label = label, expectation = expectation, probe = Probe(v) }
  end

  -- Controls. These are authored right here; nothing about them can be secret.
  add("control/number",   "MUST be readable", function() return 47788 end)
  add("control/string",   "MUST be readable", function() return "plain" end)
  add("control/table",    "MUST be readable", function() return {} end)
  add("control/nil",      "MUST be readable", function() return nil end)
  add("control/function", "MUST be readable", function() return Probe end)

  -- Candidates annotated or suspected secret. Each is fetched inside its own pcall, and the
  -- fetched value is handed straight to Probe() without being touched.
  local tl = _G["C_EncounterTimeline"]
  if type(tl) == "table" and type(tl.GetEventList) == "function" and type(tl.GetEventInfo) == "function" then
    add("timeline/spellID", "BigWigs annotates SECRET", function()
      local list = tl.GetEventList()
      if type(list) ~= "table" or list[1] == nil then error("no timeline events", 0) end
      local info = tl.GetEventInfo(list[1])
      if type(info) ~= "table" then error("GetEventInfo returned " .. type(info), 0) end
      return info.spellID
    end)
    add("timeline/duration", "BigWigs annotates readable", function()
      local list = tl.GetEventList()
      if type(list) ~= "table" or list[1] == nil then error("no timeline events", 0) end
      local info = tl.GetEventInfo(list[1])
      if type(info) ~= "table" then error("GetEventInfo returned " .. type(info), 0) end
      return info.duration
    end)
  else
    out[#out + 1] = { label = "timeline/*", expectation = "BigWigs annotates SECRET",
                      unavailable = "C_EncounterTimeline.GetEventList/GetEventInfo unavailable" }
  end

  local auras = _G["C_UnitAuras"]
  if type(auras) == "table" and type(auras.GetAuraDataByIndex) == "function" then
    add("boss1/aura.spellId", "suspected SECRET on hostile units", function()
      local data = auras.GetAuraDataByIndex("boss1", 1)
      if type(data) ~= "table" then error("no aura data on boss1", 0) end
      return data.spellId
    end)
  else
    out[#out + 1] = { label = "boss1/aura.spellId", expectation = "suspected SECRET on hostile units",
                      unavailable = "C_UnitAuras.GetAuraDataByIndex unavailable" }
  end

  add("target/UnitGUID",   "suspected SECRET for players", function() return UnitGUID("target") end)
  add("target/UnitHealth", "suspected readable",           function() return UnitHealth("target") end)
  add("boss1/UnitGUID",    "suspected readable",           function() return UnitGUID("boss1") end)

  return out
end

local function RunOracle()
  local r = EnsureRun()
  local ok, res = pcall(OracleCandidates)
  if ok then
    r.oracle = res
  else
    r.oracle = nil
    Note("oracle error: " .. tostring(res))
  end
  return r.oracle
end

-- ---------------------------------------------------------------------------
-- Encounter / boss / timeline field probing
-- ---------------------------------------------------------------------------

local function ProbeEncounterArgs(label, encounterID, encounterName, difficultyID, groupSize, success)
  return {
    label         = label,
    encounterID   = Probe(encounterID),
    encounterName = Probe(encounterName),
    difficultyID  = Probe(difficultyID),
    groupSize     = Probe(groupSize),
    success       = Probe(success),
  }
end

local function ProbeBossUnits()
  local out = {}
  for i = 1, 8 do
    local unit = "boss" .. i
    local okExists, exists = pcall(UnitExists, unit)
    if okExists and exists then
      -- Mixed value types on purpose: `unit` is a string, every probed field is a descriptor
      -- table. Annotated so LuaLS does not infer table<string,string> from the first key.
      ---@type table<string, any>
      local entry = { unit = unit }
      local function grab(field, fn, ...)
        if type(fn) ~= "function" then
          entry[field] = { secret = "api-missing", accessible = "api-missing",
                           type = "<none>", value = "<none>" }
          return
        end
        local ok, v = pcall(fn, ...)
        entry[field] = ok and Probe(v)
                          or { secret = "call-errored", accessible = "call-errored",
                               type = "<none>", value = tostring(v) }
      end
      grab("name",           UnitName, unit)
      grab("guid",           UnitGUID, unit)
      grab("health",         UnitHealth, unit)
      grab("healthMax",      UnitHealthMax, unit)
      grab("classification", _G["UnitClassification"], unit)
      grab("level",          UnitLevel, unit)
      grab("castingInfo",    _G["UnitCastingInfo"], unit)
      out[#out + 1] = entry
    end
  end
  return out
end

-- BigWigs annotates C_EncounterTimeline event info as spellID/spellName/iconFileID secret,
-- source/duration/maxQueueDuration readable. This measures that claim on the live client
-- rather than trusting the annotation.
local function ProbeEncounterTimeline()
  local api = _G["C_EncounterTimeline"]
  if type(api) ~= "table" then return { unavailable = "C_EncounterTimeline does not exist" } end
  if type(api.GetEventList) ~= "function" then return { unavailable = "GetEventList does not exist" } end

  local okList, list = pcall(api.GetEventList)
  if not okList then return { unavailable = "GetEventList errored: " .. tostring(list) } end
  if type(list) ~= "table" then return { unavailable = "GetEventList returned " .. type(list) } end

  local out = { count = #list, events = {} }
  for i = 1, math.min(#list, MAX_TIMELINE) do
    local eventID = list[i]
    local entry = { eventID = Probe(eventID) }
    if type(api.GetEventInfo) == "function" then
      local okInfo, info = pcall(api.GetEventInfo, eventID)
      if okInfo and type(info) == "table" then
        for _, field in ipairs({ "spellID", "spellName", "iconFileID", "source",
                                 "duration", "maxQueueDuration" }) do
          local okF, v = pcall(function() return info[field] end)
          entry[field] = okF and Probe(v)
                             or { secret = "field-read-errored", accessible = "field-read-errored",
                                  type = "<none>", value = tostring(v) }
        end
      else
        entry.error = "GetEventInfo: " .. tostring(info)
      end
    end
    out.events[#out.events + 1] = entry
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Frames
--
-- Two frames on purpose. RegisterUnitEvent is a whole-frame filtering mode, so the cast watcher
-- gets its own frame rather than sharing one with the encounter events — and it keeps the
-- "can we even register this?" finding attributable to one specific frame.
-- ---------------------------------------------------------------------------

-- NS001: frames are anonymous and held in locals — no named frames in this addon.
local encounterFrame = CreateFrame("Frame")
local castFrame      = CreateFrame("Frame")

local function SafeRegister(frame, event)
  local ok, err = pcall(frame.RegisterEvent, frame, event)
  if not ok then return false, tostring(err) end
  return true, nil
end

local function SafeRegisterUnit(frame, event, unit)
  local ok, err = pcall(frame.RegisterUnitEvent, frame, event, unit)
  if not ok then return false, tostring(err) end
  return true, nil
end

-- The known-forbidden control for (C). COMBAT_LOG_EVENT_UNFILTERED is documented to raise
-- ADDON_ACTION_FORBIDDEN on 12.0. If registering it produces no forbidden event, the detector is
-- broken and "UNIT_SPELLCAST_SUCCEEDED produced no forbidden event" means nothing. Opt-in, on a
-- throwaway frame, because it deliberately trips a taint warning.
local function RunForbiddenControl()
  local r = EnsureRun()
  -- Counted off the UNCAPPED counter, not #r.forbidden: once MAX_FORBIDDEN records exist the
  -- table stops growing and a control that DID fire would score as if it had not.
  local before = r.forbiddenSeen or 0

  -- Open the attribution window BEFORE the provoking call, so every record the control causes is
  -- tagged at capture time rather than reconstructed later.
  local ctlFuncs = {}
  forbiddenControlWindow = { funcs = ctlFuncs }

  local probeFrame = CreateFrame("Frame")
  local ok, err = SafeRegister(probeFrame, "COMBAT_LOG_EVENT_UNFILTERED")
  pcall(probeFrame.UnregisterAllEvents, probeFrame)

  r.forbiddenControl = {
    ranAt = date("%H:%M:%S"),
    registerCall = ok and "permitted" or ("refused: " .. tostring(err)),
    recordsBefore = before,
    funcs = ctlFuncs,
  }
  Say("forbidden control (COMBAT_LOG_EVENT_UNFILTERED): register call " ..
      (ok and (C_WARN .. "permitted" .. C_OFF) or (C_BAD .. "refused" .. C_OFF .. " — " .. tostring(err))))
  Say(C_DIM .. "records it provokes are attributed to the control and excluded from (C)." .. C_OFF)

  -- The event lands asynchronously; give it a frame or two before scoring and before closing the
  -- window. Closing it late is the safe direction: a stray record swept in with the control is a
  -- lost data point, one wrongly left out is a fabricated FAIL.
  C_Timer.After(2, function()
    local after = r.forbiddenSeen or 0
    forbiddenControlWindow = nil
    r.forbiddenControl.recordsAfter = after
    local fired = (after > before)
    r.forbiddenControl.detectorWorks = fired
    Say("forbidden control: ADDON_ACTION_* " ..
        (fired and (C_GOOD .. "FIRED — detector works" .. C_OFF)
                or (C_WARN .. "did not fire — detector unproven, treat (C) as INCONCLUSIVE" .. C_OFF)))
  end)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function EnsureDB()
  if type(PeaversRaidTimingsSpikeDB) ~= "table" then PeaversRaidTimingsSpikeDB = {} end
  local db = PeaversRaidTimingsSpikeDB
  -- Schema 1 runs have no identity, so SaveRun() cannot dedupe against them and their history is
  -- the duplicate-riddled kind this build exists to stop producing. Discard rather than migrate.
  if db.schema ~= DB_SCHEMA then
    db.schema = DB_SCHEMA
    db.runs = {}
    db.lastRun = nil
  end
  if type(db.runs) ~= "table" then db.runs = {} end
  if type(db.client) ~= "table" then
    local ok, version, build, dateStr, tocversion = pcall(GetBuildInfo)
    db.client = ok and {
      version = tostring(version), build = tostring(build),
      date = tostring(dateStr), toc = tostring(tocversion),
    } or { error = "GetBuildInfo failed" }
  end
  return db
end

-- B9: SaveRun is called on every /prtspike, and the README tells the user /prtspike is safe
-- mid-fight. Appending unconditionally meant 12 mid-pull calls wrote 12 copies of ONE run and
-- pushed every other run out of a 10-slot history. Runs carry an id; saving an already-saved run
-- REPLACES it in place.
local function SaveRun()
  if not run then return end
  local db = EnsureDB()
  run.finishedAt = date("%Y-%m-%d %H:%M:%S")

  local slot
  for i = 1, #db.runs do
    if type(db.runs[i]) == "table" and db.runs[i].id == run.id then slot = i break end
  end
  if slot then
    db.runs[slot] = run
  else
    db.runs[#db.runs + 1] = run
  end

  while #db.runs > MAX_RUNS do table.remove(db.runs, 1) end
  db.lastRun = run
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local function ReportTts(r)
  SayRaw(" ")
  SayRaw(TAG .. "|cffffffff(A) TextToSpeech_Speak — DOES IT MAKE SOUND?|r")
  local t = r.tts
  if type(t) ~= "table" or not t.a then
    SayRaw("  " .. C_WARN .. "not run — use /prtspike tts" .. C_OFF)
  else
    local a = t.a
    SayRaw("  signature: " .. C_DIM .. tostring(a.signature or "n/a") .. C_OFF)
    SayRaw("  call:      " .. (a.ok and (C_GOOD .. "permitted" .. C_OFF)
                                     or (C_BAD .. "blocked: " .. tostring(a.err) .. C_OFF)))
    if a.voice then
      SayRaw("  voice:     " .. Fmt(a.voice))
      SayRaw("  voice shape: " .. tostring(a.voiceShape) .. "   voiceID: " .. tostring(a.voiceID))
      if a.voiceShape ~= "table" and a.voiceShape ~= nil then
        SayRaw("  " .. C_WARN .. "GetSelectedVoice did NOT return a table — we passed the wrong " ..
               "shape, so any failure above is OURS, not the client's." .. C_OFF)
      end
    end
    if a.settings then
      SayRaw("  tts settings: rate=" .. tostring(a.settings.rate))
      SayRaw("                volume=" .. tostring(a.settings.volume))
      SayRaw("                voices available=" .. tostring(a.settings.voiceCount))
      SayRaw("  " .. C_DIM .. "a volume of 0 makes a permitted call silent — check this before " ..
             "concluding addon TTS is blocked." .. C_OFF)
    end

    -- NOT `x and t.confirmed.a or nil`. That idiom collapses a stored `false` to `nil`, and
    -- `false` here is the human saying they heard NOTHING — the entire negative finding. With the
    -- and/or form the "permitted but SILENT" branch below was unreachable: a reported silence
    -- printed as UNCONFIRMED, i.e. the one result that would sink the product was discarded.
    local confirmed
    if type(t.confirmed) == "table" then confirmed = t.confirmed.a end

    -- Silence has causes that are nothing to do with addon permissions. Each is checked BEFORE
    -- a definite FAIL is printed, because (A) is a headline go/no-go question and "your volume
    -- slider is at 0" must never be reported as "the client silences addon TTS".
    local st = a.settings
    local muted     = type(st) == "table" and type(st.volumeNum) == "number" and st.volumeNum <= 0
    local noVoices  = type(st) == "table" and st.voiceCountNum == 0
    -- We only know the shape when the voice value was readable; "<not touched>" means unknown.
    local wrongShape = a.voiceShape ~= nil and a.voiceShape ~= "table"
                       and a.voiceShape ~= "<not touched>" and a.voiceShape ~= "nil"

    local verdict
    if not a.ok then
      if wrongShape then
        verdict = C_WARN .. "INCONCLUSIVE — the call failed, but GetSelectedVoice returned a " ..
                  tostring(a.voiceShape) .. ", not a table. We passed the wrong shape, so this " ..
                  "failure is OURS, not the client's." .. C_OFF
      else
        verdict = C_BAD .. "FAIL — call blocked, no audio possible: " .. tostring(a.err) .. C_OFF
      end
    elseif confirmed == true then
      verdict = C_GOOD .. "PASS — AUDIBLE. Human matched the spoken word." .. C_OFF
    elseif confirmed == false and muted then
      verdict = C_WARN .. "INCONCLUSIVE — nothing was heard, but speech volume is " ..
                tostring(st.volumeNum) .. ". A permitted call at volume 0 is silent by design. " ..
                "Raise it and re-run /prtspike tts." .. C_OFF
    elseif confirmed == false and noVoices then
      verdict = C_WARN .. "INCONCLUSIVE — nothing was heard, but this client reports 0 installed " ..
                "TTS voices. Install one and re-run /prtspike tts." .. C_OFF
    elseif confirmed == false then
      verdict = C_BAD .. "FAIL — call permitted but SILENT. Human heard nothing, and volume/" ..
                "voices are not the cause." .. C_OFF
    else
      verdict = C_WARN .. "UNCONFIRMED — call permitted, audibility not yet reported. " ..
                "Run /prtspike tts and answer /prtspike heard <word>." .. C_OFF
    end
    SayRaw("  VERDICT (A): " .. verdict)
    if type(t.reports) == "table" and #t.reports > 0 then
      SayRaw("  " .. C_DIM .. "human reports: " .. table.concat(t.reports, ", ") .. C_OFF)
    end
  end

  SayRaw(" ")
  SayRaw(TAG .. "|cffffffff(B) C_CombatAudioAlert.SpeakText — does it error for tainted code?|r")
  local b = type(t) == "table" and t.b or nil
  if not b then
    SayRaw("  " .. C_WARN .. "not run — use /prtspike tts (path B fires 3s after path A)" .. C_OFF)
  else
    if b.isEnabled then SayRaw("  IsEnabled():  " .. tostring(b.isEnabled)) end
    SayRaw("  category:     " .. tostring(b.categoryUsed) ..
           (b.categoryFallback and ("  " .. C_WARN .. "(fallback — Enum.CombatAudioAlertCategory " ..
                                    "absent on this client)" .. C_OFF) or ""))

    -- ok=false has four causes and only ONE of them answers (B). The API being absent, or our own
    -- probe erroring, says nothing whatsoever about how the client treats tainted callers.
    local outcome = b.outcome or (b.ok and "permitted" or "call-errored")
    if outcome == "permitted" then
      -- Same and/or trap as (A): a stored `false` must survive as `false`.
      local confirmed
      if type(t.confirmed) == "table" then confirmed = t.confirmed.b end
      SayRaw("  VERDICT (B): " .. C_GOOD .. "call PERMITTED for tainted addon code" .. C_OFF ..
             (confirmed == true and (" — and " .. C_GOOD .. "AUDIBLE" .. C_OFF)
              or confirmed == false and (" — but " .. C_BAD .. "SILENT" .. C_OFF)
              or (" — " .. C_WARN .. "audibility unconfirmed" .. C_OFF)))
    elseif outcome == "api-absent" then
      SayRaw("  VERDICT (B): " .. C_WARN .. "INCONCLUSIVE — the API does not exist on this " ..
             "client, so its taint behaviour cannot be tested. This is NOT a block." .. C_OFF)
      SayRaw("  detail: " .. C_DIM .. tostring(b.err) .. C_OFF)
    elseif outcome == "probe-errored" then
      SayRaw("  VERDICT (B): " .. C_WARN .. "INCONCLUSIVE — our own probe errored before reaching " ..
             "the API. The failure is OURS, not the client's." .. C_OFF)
      SayRaw("  detail: " .. C_DIM .. tostring(b.err) .. C_OFF)
    elseif b.categoryFallback then
      SayRaw("  VERDICT (B): " .. C_WARN .. "INCONCLUSIVE — the call errored, but we passed a " ..
             "fallback category (0) because the enum is absent. A rejected argument and a taint " ..
             "refusal are indistinguishable from here." .. C_OFF)
      SayRaw("  exact failure: " .. C_BAD .. tostring(b.err) .. C_OFF)
    else
      SayRaw("  VERDICT (B): " .. C_BAD .. "ERRORED for tainted addon code" .. C_OFF)
      SayRaw("  exact failure: " .. C_BAD .. tostring(b.err) .. C_OFF)
    end
  end
end

local function ReportForbidden(r)
  SayRaw(" ")
  SayRaw(TAG .. "|cffffffff(C) RegisterUnitEvent(\"UNIT_SPELLCAST_SUCCEEDED\", \"player\") — forbidden?|r")

  SayRaw("  register call at load: " ..
    (registration.castOk and (C_GOOD .. "permitted" .. C_OFF)
                          or (C_BAD .. "REFUSED: " .. tostring(registration.castErr) .. C_OFF)))

  local reg = r.unitRegistrationDuringEncounter
  if reg ~= nil then
    SayRaw("  re-register during encounter: " ..
      (reg == true and (C_GOOD .. "permitted" .. C_OFF) or (C_BAD .. tostring(reg) .. C_OFF)))
  end

  -- Records naming this addon are split by PROVENANCE before anything is counted. The detector
  -- control provokes forbidden events naming us on purpose; counting those as evidence about the
  -- API under test is what made this verdict come out backwards.
  local c = ClassifyForbidden(r)
  SayRaw(string.format("  ADDON_ACTION_* events this run: %d  (naming this addon: %d)",
    #(r.forbidden or {}), #c.control + #c.relevant + #c.unattributed))

  local function listRecs(label, colour, recs)
    if #recs == 0 then return end
    SayRaw("    " .. colour .. label .. ": " .. tostring(#recs) .. C_OFF)
    for i = 1, math.min(#recs, 5) do
      SayRaw("      " .. tostring(recs[i].event) .. " " .. tostring(recs[i].func) ..
             " at " .. tostring(recs[i].at))
    end
  end
  listRecs("provoked by the detector control (EXPECTED, excluded from the verdict)", C_DIM, c.control)
  listRecs("on the API under test (evidence for (C))", C_BAD, c.relevant)
  listRecs("naming us for an unrelated func (not an answer to (C))", C_WARN, c.unattributed)
  if c.other > 0 then
    SayRaw("    " .. C_DIM .. tostring(c.other) .. " from other addons (informational)" .. C_OFF)
  end

  local ctl = r.forbiddenControl
  if ctl then
    SayRaw("  detector control (COMBAT_LOG_EVENT_UNFILTERED): register " .. tostring(ctl.registerCall) ..
           ", ADDON_ACTION_* " ..
           (ctl.detectorWorks == true and (C_GOOD .. "fired" .. C_OFF)
            or ctl.detectorWorks == false and (C_WARN .. "did not fire" .. C_OFF)
            or (C_DIM .. "still pending" .. C_OFF)))
  end

  local code, text = ForbiddenVerdict(r, registration)
  local colour = (code == "PASS" and C_GOOD) or (code == "FAIL" and C_BAD) or C_WARN
  SayRaw("  VERDICT (C): " .. colour .. text .. C_OFF)
end

local function ReportOracle(r)
  SayRaw(" ")
  SayRaw(TAG .. "|cffffffff(D) canaccessvalue / issecretvalue — RAW returns on real values|r")

  SayRaw("  issecretvalue:  " .. (isSecretFn and (C_GOOD .. "present" .. C_OFF) or (C_BAD .. "ABSENT" .. C_OFF)))
  SayRaw("  canaccessvalue: " .. (canAccessFn and (C_GOOD .. "present" .. C_OFF) or (C_BAD .. "ABSENT" .. C_OFF)))

  local o = r.oracle
  if type(o) ~= "table" or #o == 0 then
    SayRaw("  " .. C_WARN .. "not run — use /prtspike oracle" .. C_OFF)
    return
  end

  -- A control can fail in two completely different ways and they are NOT the same finding:
  --   lying       — the gates gave a definite answer, and it was wrong about an authored value.
  --                 That voids every secrecy finding in the report.
  --   unprobeable — the gates never answered at all. That voids nothing; it means we learned
  --                 nothing, and must be reported as INCONCLUSIVE, not as INVALID.
  local controlsOk, controlsTotal, controlsLying, controlsUnprobeable = 0, 0, 0, 0
  -- Question (D) is specifically about canaccessvalue. A run where only issecretvalue answered
  -- can look like sound controls while the function under test never spoke once.
  local accessAnswered = 0

  for _, c in ipairs(o) do
    SayRaw("  " .. tostring(c.label) .. C_DIM .. "  [" .. tostring(c.expectation) .. "]" .. C_OFF)
    if c.unavailable then
      SayRaw("    " .. C_DIM .. "unavailable: " .. tostring(c.unavailable) .. C_OFF)
    else
      SayRaw("    " .. Fmt(c.probe))
      SayRaw("    " .. FmtRaw(c.probe))
      local isControl = (string.sub(tostring(c.label), 1, 8) == "control/")
      if isControl then
        controlsTotal = controlsTotal + 1
        if not ProbeConclusive(c.probe) then
          controlsUnprobeable = controlsUnprobeable + 1
        elseif ProbeReadable(c.probe) then
          controlsOk = controlsOk + 1
        else
          controlsLying = controlsLying + 1
        end
        if type(c.probe) == "table" and type(c.probe.accessible) == "boolean" then
          accessAnswered = accessAnswered + 1
        end
      elseif type(c.probe) == "table" and ProbeReadable(c.probe) and c.probe.type == "nil" then
        -- No target, no aura, not in an encounter. The candidate produced no sample, so its
        -- "readable" line says nothing about the secrecy of the value it was meant to fetch.
        SayRaw("    " .. C_WARN .. "NO SAMPLE — the source returned nil (no target / no aura / " ..
               "not in an encounter). This line is not evidence about that value." .. C_OFF)
      end
    end
  end

  local verdict
  if not canAccessFn then
    verdict = C_WARN .. "INCONCLUSIVE — canaccessvalue is ABSENT on this client. (D) asks what " ..
              "that function returns, and it cannot be answered here, however sound the " ..
              "issecretvalue side looks." .. C_OFF
  elseif controlsTotal == 0 then
    verdict = C_WARN .. "INCONCLUSIVE — no controls scored." .. C_OFF
  elseif controlsLying > 0 then
    verdict = C_BAD .. string.format("INVALID — %d/%d authored controls came back SECRET. The " ..
              "gates are wrong or we are calling them wrong; every secrecy finding in this " ..
              "report is void.", controlsLying, controlsTotal) .. C_OFF
  elseif controlsOk == 0 then
    verdict = C_WARN .. string.format("INCONCLUSIVE — %d/%d controls were UNPROBEABLE and none " ..
              "got a definite answer. Nothing may be concluded in either direction.",
              controlsUnprobeable, controlsTotal) .. C_OFF
  elseif accessAnswered == 0 then
    verdict = C_WARN .. "INCONCLUSIVE — canaccessvalue exists but never returned a boolean for " ..
              "any control, so its behaviour is still unmeasured." .. C_OFF
  else
    verdict = C_GOOD .. string.format("controls sound (%d/%d readable, %d unprobeable; " ..
              "canaccessvalue answered for %d). Raw returns above are trustworthy.",
              controlsOk, controlsTotal, controlsUnprobeable, accessAnswered) .. C_OFF
  end
  SayRaw("  VERDICT (D): " .. verdict)
end

local function ReportCasts(r)
  SayRaw(" ")
  SayRaw(TAG .. "|cffffffffROUTINE CHECK — UNIT_SPELLCAST_SUCCEEDED spellID (doc-drift guard)|r")
  SayRaw("  " .. C_DIM .. "Blizzard documents this as readable and comparable. This is a cheap " ..
         "re-confirmation, not a gate." .. C_OFF)

  local t = r.castTotals
  SayRaw(string.format("  events seen: %d   readable: %d   fully comparable: %d   unprobeable: %d",
    t.seen, t.readable, t.comparable, t.unprobeable or 0))

  local sample = r.casts[1]
  if not sample then
    SayRaw("  " .. C_WARN .. "no casts captured — cast something, then re-run /prtspike" .. C_OFF)
  else
    SayRaw("  first sample:")
    SayRaw("    spellID   " .. Fmt(sample.spellID))
    SayRaw("    castGUID  " .. Fmt(sample.castGUID))
    SayRaw("    unitTarget " .. Fmt(sample.unitTarget))
    local c = sample.comparability
    if c then
      -- Decisive tests (these drive the verdict).
      SayRaw("    tonumber         " .. FmtTry(c.tonumber))
      SayRaw("    arithmetic +0    " .. FmtTry(c.arithmetic))
      SayRaw("    table key rt     " .. FmtTry(c.tableKey))
      SayRaw("    == self          " .. FmtTry(c.selfEquality))
      -- Informational: a `false` here just means you cast something other than the sample id.
      SayRaw("    " .. C_DIM .. "== literal (info)" .. C_OFF .. "       " .. FmtTry(c.litEquality))
      SayRaw("    " .. C_DIM .. "our-table lookup (info)" .. C_OFF .. " " .. FmtTry(c.lookupOurTable))
      SayRaw("    " .. C_DIM .. "string.format (info)" .. C_OFF .. "    " .. FmtTry(c.stringFormat))
    end
  end

  -- B10: ONE definition of readable (ProbeReadable), and absence of the probe APIs is its own
  -- rung. The old build could report "FAIL — spellID is secret" for a perfectly readable number
  -- purely because the probe APIs were missing, and "PARTIAL" for a value it had printed SECRET.
  local verdict
  if t.seen == 0 then
    verdict = C_WARN .. "INCONCLUSIVE — no events captured." .. C_OFF
  elseif t.comparable > 0 then
    verdict = C_GOOD .. "PASS — spellID is readable AND comparable, as documented." .. C_OFF
  elseif (t.unprobeable or 0) >= t.seen then
    verdict = C_WARN .. "INCONCLUSIVE — probe APIs unavailable; secrecy could not be determined " ..
              "in either direction." .. C_OFF
  elseif t.readable > 0 then
    verdict = C_WARN .. "PARTIAL — readable but not fully comparable. Check which battery entry failed." .. C_OFF
  else
    -- Cite the counts: on a mixed run this FAIL rests only on the events that got a definite
    -- answer, and the reader needs to see how many that was before acting on it.
    verdict = C_BAD .. string.format("FAIL — spellID is secret in all %d event(s) the probe APIs " ..
              "answered for (%d of %d seen were unprobeable). Blizzard's documentation has drifted.",
              t.seen - (t.unprobeable or 0), t.unprobeable or 0, t.seen) .. C_OFF
  end
  SayRaw("  VERDICT (routine): " .. verdict)
end

local function ReportEncounter(r)
  SayRaw(" ")
  SayRaw(TAG .. "|cffffffffSUPPORTING — encounter / boss / timeline field secrecy|r")

  for _, key in ipairs({ "encounterStart", "encounterEnd" }) do
    local e = r[key]
    if e then
      SayRaw("  " .. tostring(e.label) .. ":")
      for _, field in ipairs({ "encounterID", "encounterName", "difficultyID", "groupSize", "success" }) do
        if e[field] then SayRaw("    " .. field .. string.rep(" ", 15 - #field) .. Fmt(e[field])) end
      end
    end
  end

  if r.bossUnits and #r.bossUnits > 0 then
    for _, b in ipairs(r.bossUnits) do
      SayRaw("  " .. tostring(b.unit) .. ":")
      for _, field in ipairs({ "name", "guid", "health", "healthMax", "classification", "level", "castingInfo" }) do
        if b[field] then SayRaw("    " .. field .. string.rep(" ", 16 - #field) .. Fmt(b[field])) end
      end
    end
  else
    SayRaw("  boss units: " .. C_DIM .. "none present at probe time" .. C_OFF)
  end

  local tl = r.timeline
  if tl and tl.unavailable then
    SayRaw("  C_EncounterTimeline: " .. C_WARN .. tostring(tl.unavailable) .. C_OFF)
  elseif tl and tl.events and #tl.events > 0 then
    SayRaw(string.format("  C_EncounterTimeline: %d events, sampling %d", tl.count or 0, #tl.events))
    local e = tl.events[1]
    for _, field in ipairs({ "eventID", "spellID", "spellName", "iconFileID",
                             "source", "duration", "maxQueueDuration" }) do
      if e[field] then SayRaw("    " .. field .. string.rep(" ", 18 - #field) .. Fmt(e[field])) end
    end
  else
    SayRaw("  C_EncounterTimeline: " .. C_DIM .. "no events at probe time" .. C_OFF)
  end
end

local function Report(r)
  r = r or run or (PeaversRaidTimingsSpikeDB and PeaversRaidTimingsSpikeDB.lastRun)
  if not r then
    -- Do NOT bail. The most decisive outcome the spike can have is UNIT_SPELLCAST_SUCCEEDED
    -- registration being REFUSED — and that outcome guarantees no cast ever arrives, so no run
    -- is ever created by capture, so bailing here meant `/prtspike` answered the product's
    -- go/no-go question with "no run recorded yet, cast a spell and try again". The verdicts are
    -- meaningful on an empty run: (C) reports the refusal, the rest report INCONCLUSIVE.
    Say(C_DIM .. "no captures yet — reporting on an empty run so the verdicts still print." .. C_OFF)
    r = EnsureRun()
  end
  SayRaw(" ")
  SayRaw(TAG .. "|cffffffff==== SPIKE REPORT (" .. tostring(r.kind) .. ", " ..
         tostring(r.id) .. ", " .. tostring(r.startedAt) .. ") ====|r")
  if r.encounter then SayRaw("  encounter: " .. tostring(r.encounter)) end
  -- The open questions lead. The routine check follows.
  ReportTts(r)
  ReportForbidden(r)
  ReportOracle(r)
  ReportCasts(r)
  ReportEncounter(r)
  if #r.notes > 0 then
    SayRaw(" ")
    SayRaw("  notes:")
    for _, n in ipairs(r.notes) do SayRaw("    - " .. tostring(n)) end
  end
  SayRaw(TAG .. "|cffffffffFull detail is in PeaversRaidTimingsSpikeDB (logout/reload to flush).|r")
  SayRaw(" ")
end

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

local function OnCastSucceeded(unitTarget, castGUID, spellID)
  local r = EnsureRun()
  session.castEvents = session.castEvents + 1
  r.castTotals.seen = r.castTotals.seen + 1

  local spellProbe = Probe(spellID)

  -- B10: the SAME readability definition ComparabilityPassed uses. Nothing else may define it.
  if not ProbeConclusive(spellProbe) then
    r.castTotals.unprobeable = (r.castTotals.unprobeable or 0) + 1
  elseif ProbeReadable(spellProbe) then
    r.castTotals.readable = r.castTotals.readable + 1
    session.castReadable = session.castReadable + 1
  end

  local comparability = Comparability(spellID)
  if ComparabilityPassed(spellProbe, comparability) then
    r.castTotals.comparable = r.castTotals.comparable + 1
    session.castComparable = session.castComparable + 1
  end

  if #r.casts < MAX_CAST_SAMPLES then
    r.casts[#r.casts + 1] = {
      spellID       = spellProbe,
      castGUID      = Probe(castGUID),
      unitTarget    = Probe(unitTarget),
      comparability = comparability,
    }
  end
end

castFrame:SetScript("OnEvent", function(_, event, ...)
  if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
  -- The handler is pcall'd as a unit: a probe that errors must not break the encounter.
  local ok, err = pcall(OnCastSucceeded, ...)
  if not ok then
    Say(C_BAD .. "cast probe errored (recorded, continuing): " .. C_OFF .. tostring(err))
    Note("cast probe error: " .. tostring(err))
  end
end)

local function OnEncounterStart(encounterID, encounterName, difficultyID, groupSize)
  run = NewRun("encounter")
  local r = run   -- captured: async closures below must never file into a later run
  r.encounterStart = ProbeEncounterArgs("ENCOUNTER_START", encounterID, encounterName,
                                        difficultyID, groupSize, nil)
  r.encounter = tostring(r.encounterStart.encounterID.value) .. " / " ..
                tostring(r.encounterStart.encounterName.value)

  -- DBM is reported to block registration of every UNIT_* event DURING an encounter. Our own
  -- registration happened at load, out of combat; this tests the mid-encounter case on a
  -- throwaway frame so a refusal cannot disturb the real watcher.
  local probeFrame = CreateFrame("Frame")
  local ok, err = SafeRegisterUnit(probeFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
  r.unitRegistrationDuringEncounter = ok and true or ("blocked: " .. tostring(err))
  pcall(probeFrame.UnregisterAllEvents, probeFrame)

  Say("encounter started — capturing. " .. C_DIM .. "/prtspike at any time." .. C_OFF)

  -- Boss units and the timeline are empty at the instant of ENCOUNTER_START; probe once they
  -- have populated. `r` is captured rather than re-reading the `run` upvalue: on a fast wipe the
  -- encounter can already have ended and a new run begun by the time this fires, and the old
  -- version wrote boss-unit data into whatever run happened to be current.
  C_Timer.After(5, function()
    local okB, bosses = pcall(ProbeBossUnits)
    if okB then r.bossUnits = bosses else r.notes[#r.notes + 1] = "boss probe error: " .. tostring(bosses) end
    local okT, tl = pcall(ProbeEncounterTimeline)
    if okT then r.timeline = tl else r.notes[#r.notes + 1] = "timeline probe error: " .. tostring(tl) end
    local okO, oracle = pcall(OracleCandidates)
    if okO then r.oracle = oracle else r.notes[#r.notes + 1] = "oracle error: " .. tostring(oracle) end
  end)
end

local function OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
  local r = EnsureRun()
  r.encounterEnd = ProbeEncounterArgs("ENCOUNTER_END", encounterID, encounterName,
                                      difficultyID, groupSize, success)
  SaveRun()
  Report(r)
  run = nil
end

encounterFrame:SetScript("OnEvent", function(_, event, ...)
  local handler
  if event == "ENCOUNTER_START" then handler = OnEncounterStart
  elseif event == "ENCOUNTER_END" then handler = OnEncounterEnd
  elseif event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
    handler = function(...) RecordForbidden(event, ...) end
  elseif event == "PLAYER_LOGIN" then
    handler = function()
      EnsureDB()
      Say("loaded. " .. C_DIM ..
          "/prtspike report | tts | heard | forbidden | selftest | oracle | probe | save | wipe" .. C_OFF)
      -- The verdict logic checks itself at load. A spike that reports the wrong answer is worse
      -- than no spike, so a broken (C) scorer must announce itself before anyone reads a verdict.
      local okST, _, failed = pcall(SelfTestForbidden)
      if not okST then
        Say(C_BAD .. "verdict self-test ERRORED — do not trust verdict (C)." .. C_OFF)
      elseif (failed or 0) > 0 then
        Say(C_BAD .. "verdict self-test FAILED (" .. tostring(failed) .. ") — do not trust " ..
            "verdict (C). Run /prtspike selftest." .. C_OFF)
      end
      Say("start here: " .. C_WARN .. "/prtspike tts" .. C_OFF .. " — then type the word you heard.")
    end
  end
  if not handler then return end
  local ok, err = pcall(handler, ...)
  if not ok then
    Say(C_BAD .. "error in " .. tostring(event) .. " (recorded, continuing): " .. C_OFF .. tostring(err))
    Note(tostring(event) .. " error: " .. tostring(err))
  end
end)

-- ---------------------------------------------------------------------------
-- Registration
--
-- Registration itself is a finding for question (C), and the pcall result is only half of it —
-- the forbidden path fires an event rather than erroring, so ADDON_ACTION_* is registered too.
-- ---------------------------------------------------------------------------

do
  local okLogin = SafeRegister(encounterFrame, "PLAYER_LOGIN")
  local okStart, errStart = SafeRegister(encounterFrame, "ENCOUNTER_START")
  local okEnd, errEnd = SafeRegister(encounterFrame, "ENCOUNTER_END")
  SafeRegister(encounterFrame, "ADDON_ACTION_FORBIDDEN")
  SafeRegister(encounterFrame, "ADDON_ACTION_BLOCKED")
  if not okLogin then Say(C_BAD .. "PLAYER_LOGIN registration blocked" .. C_OFF) end
  if not okStart then Say(C_BAD .. "ENCOUNTER_START registration blocked: " .. C_OFF .. tostring(errStart)) end
  if not okEnd then Say(C_BAD .. "ENCOUNTER_END registration blocked: " .. C_OFF .. tostring(errEnd)) end

  local okCast, errCast = SafeRegisterUnit(castFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
  registration.castOk = okCast and true or false
  registration.castErr = errCast
  registration.at = date("%H:%M:%S")
  if not okCast then
    Say(C_BAD .. "UNIT_SPELLCAST_SUCCEEDED registration REFUSED: " .. C_OFF .. tostring(errCast))
    Say(C_BAD .. "That alone answers question (C) as a FAIL." .. C_OFF)
  end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

SLASH_PRTSPIKE1 = "/prtspike"
SlashCmdList["PRTSPIKE"] = function(msg)
  local raw = strtrim(tostring(msg or ""))
  local cmd, rest = string.match(raw, "^(%S*)%s*(.-)$")
  cmd = string.lower(cmd or "")

  if cmd == "tts" then
    local ok, err = pcall(RunTtsProbes, "manual")
    if not ok then Say(C_BAD .. "tts probe errored: " .. C_OFF .. tostring(err)) end

  elseif cmd == "heard" then
    local ok, err = pcall(RecordHeard, rest)
    if not ok then Say(C_BAD .. "heard errored: " .. C_OFF .. tostring(err)) end

  elseif cmd == "forbidden" then
    local ok, err = pcall(RunForbiddenControl)
    if not ok then Say(C_BAD .. "forbidden control errored: " .. C_OFF .. tostring(err)) end

  elseif cmd == "selftest" then
    local ok, results, failed = pcall(SelfTestForbidden)
    if not ok then
      Say(C_BAD .. "self-test errored: " .. C_OFF .. tostring(results))
    else
      SayRaw(TAG .. "|cffffffffSELF-TEST — (C) verdict logic|r")
      for _, res in ipairs(results) do
        SayRaw("  " .. (res.ok and (C_GOOD .. "ok  " .. C_OFF) or (C_BAD .. "FAIL" .. C_OFF)) ..
               " " .. tostring(res.name) .. C_DIM .. "  [" .. tostring(res.detail) .. "]" .. C_OFF)
      end
      SayRaw("  " .. (failed == 0
        and (C_GOOD .. "all checks passed — the detector control cannot fabricate a (C) FAIL." .. C_OFF)
        or (C_BAD .. tostring(failed) .. " CHECK(S) FAILED — do not trust verdict (C)." .. C_OFF)))
    end

  elseif cmd == "oracle" then
    local ok, err = pcall(RunOracle)
    if not ok then Say(C_BAD .. "oracle errored: " .. C_OFF .. tostring(err)) end
    pcall(ReportOracle, EnsureRun())

  elseif cmd == "probe" then
    local r = EnsureRun()
    local okB, bosses = pcall(ProbeBossUnits)
    if okB then r.bossUnits = bosses end
    local okT, tl = pcall(ProbeEncounterTimeline)
    if okT then r.timeline = tl end
    Say("re-probed boss units and encounter timeline.")
    pcall(ReportEncounter, r)

  elseif cmd == "save" then
    pcall(SaveRun)
    Say("current run written to PeaversRaidTimingsSpikeDB (replaced in place if already saved).")

  elseif cmd == "wipe" then
    PeaversRaidTimingsSpikeDB = nil
    run = nil
    EnsureDB()
    Say("saved results wiped.")

  elseif cmd == "help" then
    Say("/prtspike             — dump the current or last run, and persist it")
    Say("/prtspike tts         — (A)+(B) speak a random word down each TTS path")
    Say("/prtspike heard <word>— report the word you actually HEARD (or 'nothing')")
    Say("/prtspike forbidden   — (C) run the known-forbidden control to prove the detector")
    Say("/prtspike selftest    — prove the control cannot fabricate a (C) FAIL")
    Say("/prtspike oracle      — (D) raw issecretvalue/canaccessvalue returns on real values")
    Say("/prtspike probe       — re-probe boss units + encounter timeline")
    Say("/prtspike save        — persist the current run without ending it")
    Say("/prtspike wipe        — clear saved results")

  else
    local ok, err = pcall(Report, nil)
    if not ok then Say(C_BAD .. "report errored: " .. C_OFF .. tostring(err)) end
    pcall(SaveRun)
  end
end
