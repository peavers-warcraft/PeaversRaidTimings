# PeaversRaidTimingsSpike

**This is a throwaway diagnostic addon. It is never shipped, never released, and has no
CurseForge project.** It exists to answer the questions that desk research could not settle,
before any real work starts on `PeaversRaidTimings`. Once they are answered, delete it.

It has no dependency on `PeaversCommons` — deliberately. Fewer moving parts, and a framework bug
must not be able to masquerade as a client-capability finding.

## Scope: what is still open, and what is not

Independent API research **settled** one of the three questions this spike was originally built
to answer. `UNIT_SPELLCAST_SUCCEEDED` registered for unit `"player"` is confirmed by Blizzard's
documentation to deliver a readable, comparable `spellID` during encounters. That check is still
performed — it is cheap, and it guards against documentation drift — but it is now reported as a
**routine check**, not as the gate that decides whether the product is buildable.

What remains genuinely open is everything below. These are what the report leads with.

### (A) Does `TextToSpeech_Speak` actually produce **audible sound** from addon context?

Called with the full documented signature:

```lua
TextToSpeech_Speak(text, voice, neverQueue, allowOverlappedSpeech)
```

where `voice` is the **table** returned by `TextToSpeech_GetSelectedVoice(Enum.TtsVoiceType.Standard)`.

> **A permitted `pcall` is not proof of audio.** So the addon does not ask "did you hear
> something?", which invites a polite yes. It speaks **a word chosen at random and never printed
> on screen**, and you type back what you heard with `/prtspike heard <word>`. Only an exact match
> scores as audible. You cannot confirm audio you did not hear.

Two silent-but-permitted paths are ruled out explicitly rather than guessed at:

- **Queueing.** Blizzard's implementation computes
  `shouldQueue = (playbackActive or uiHidden) and not neverQueue` and a queued utterance returns
  *early, without speaking*. `neverQueue` is passed as `false` and the conditions are reported.
- **Volume.** The call ends in `C_VoiceChat.SpeakText(..., C_TTSSettings.GetSpeechVolume(), ...)`,
  so a volume of `0` is a permitted, entirely silent call. Rate, volume and available voice count
  are all printed — **check them before concluding that addon TTS is blocked.**

The voice's shape is recorded too. The contract is a table and the implementation indexes
`voice.voiceID`, so a non-table means *we* passed the wrong thing; that must never be reported as
the client blocking us.

**Those two silent-but-permitted causes are now acted on, not merely printed.** The speech volume
and installed voice count are read back as numbers, and if you report hearing nothing while volume
is `0` or no voices are installed, (A) reports `INCONCLUSIVE` with the remedy — never `FAIL`. A
`FAIL` on (A) means the call was permitted, volume and voices were fine, and it was *still* silent.
Likewise a failed call made with a non-table voice reports `INCONCLUSIVE`, because that failure is
ours.

### (B) Does `C_CombatAudioAlert.SpeakText` error for tainted addon code?

Its `SecretArguments` flag is `"AllowedWhenUntainted"` — **stricter** than `C_VoiceChat.SpeakText`'s
`AllowedWhenTainted` — and addon code is tainted. The exact failure text is captured verbatim and
printed. `IsEnabled()` and the category value used are recorded alongside it.

A failed call has **four** causes and only one of them answers (B), so the probe records which:

| Outcome | Verdict | Why |
|---|---|---|
| call permitted | `PERMITTED for tainted code` | the answer |
| call errored | `ERRORED for tainted code` + exact text | the answer |
| `C_CombatAudioAlert` not on this client | `INCONCLUSIVE` | absence of the API is not a block |
| our own probe errored first | `INCONCLUSIVE` | the failure is ours |

There is a fifth, subtler case. `Enum.CombatAudioAlertCategory.Generic` may not exist, in which case
a plain `0` is passed as the category. If the call then errors, a **rejected argument and a taint
refusal are indistinguishable**, so the verdict degrades to `INCONCLUSIVE` and says so rather than
crediting the client with a block it may not have made.

### (C) Does `RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")` raise `ADDON_ACTION_FORBIDDEN`?

A `pcall` around the register call is only half the question: **the forbidden path fires an event
rather than erroring.** So `ADDON_ACTION_FORBIDDEN` and `ADDON_ACTION_BLOCKED` are both registered
and every occurrence is attributed to an addon and a function name.

Silence is not evidence unless the detector is known to work, so `/prtspike forbidden` runs a
**known-forbidden control** — registering `COMBAT_LOG_EVENT_UNFILTERED`, documented to trip the
forbidden path on 12.0 — on a throwaway frame. If the control does not fire, (C) reports
`INCONCLUSIVE` rather than a false `PASS`. Mid-encounter re-registration is tested separately, also
on a throwaway frame, so a refusal cannot disturb the real watcher.

> **The control provokes `ADDON_ACTION_FORBIDDEN` naming this addon. That is what makes it a
> control — and it must never be read as evidence against the API under test.** An earlier build
> counted the control's own records as exactly that, and tested "did anything name us?" *before*
> "did the control prove the detector?". Following the steps above verbatim therefore printed
> `detector works` directly on top of `VERDICT (C): FAIL` — the spike arguing against the one
> detection channel the product depends on, on the strength of a taint warning it had raised itself.

Records provoked by the control are attributed to it by three independent guards — a window flag
set at capture time, the record-index range the control spanned, and the func names seen while that
window was open — and are listed separately as `EXPECTED, excluded from the verdict`. What survives
is then split again: a forbidden naming us for `RegisterUnitEvent` is evidence and reports `FAIL`;
one naming us for some unrelated func is reported as `INCONCLUSIVE`, since it is not an answer to
(C) in either direction. `detectorWorks` is checked **before** any record count, so "we have
records" can never outrank "those records are the control's own".

`/prtspike selftest` proves this on synthetic records, without a client: nine checks covering each
guard in isolation, the genuine-failure case that must still `FAIL`, and every absence-of-evidence
case that must stay `INCONCLUSIVE`. It also runs automatically at load and shouts if it fails,
because a spike that answers its own headline question backwards is worse than no spike.

### (D) What does `canaccessvalue` actually return for a genuinely secret value?

Emulating this with metatables validates *our logic against an assumed behaviour*, not the
client's. So `/prtspike oracle` probes real candidate values and prints the **raw** returns of
`issecretvalue()` / `canaccessvalue()` — type and printed form — not a coerced boolean.

The **controls are the point.** Five values authored right here in the addon (a number, a string,
a table, `nil`, a function) must come back readable. If a control reports `SECRET`, the probe APIs
are lying or we are calling them wrong, and (D) reports `INVALID` — **every other secrecy finding
in the report is then void.** Alongside the controls it probes candidates that BigWigs annotates
secret (`C_EncounterTimeline` `spellID` vs `duration`), hostile-unit aura data, and target GUID.

A control can fail in two ways that are **not** the same finding, and they are scored apart:

- **lying** — the gates answered, and the answer was wrong about a value we authored. `INVALID`.
- **unprobeable** — the gates never answered at all. That voids nothing; it means we learned
  nothing, and reports `INCONCLUSIVE`.

Question (D) is specifically about `canaccessvalue`. If that function is **absent**, (D) reports
`INCONCLUSIVE` however sound the `issecretvalue` side looks — otherwise the controls pass on
`issecretvalue` alone and the function actually under test never speaks. The same applies if it
exists but never returns a boolean for any control.

Candidate lines that came back `nil` — no target, no aura, not in an encounter — are marked
`NO SAMPLE`. A `nil` that probes as readable says nothing about the secrecy of the value it was
meant to fetch, and reading those lines as findings is how a run with no target "proves" that
`UnitGUID` is readable.

Note the two functions do **not** answer the same question:

| Call | Documented meaning |
|---|---|
| `issecretvalue(value)` | true if the supplied **value** is secret |
| `canaccessvalue(value)` | true if the **calling function** has permission to operate on secret values |

The second is a property of the caller. Tainted addon code may therefore see `accessible=false`
for a perfectly ordinary number — which is why `canaccessvalue` can only *add* readability, never
remove it, and why `secret=false` + `accessible=false` is flagged `[gates differ]` rather than
treated as an error. Confirming that reading on a live client is the whole of question (D).

### Routine check — `UNIT_SPELLCAST_SUCCEEDED` `spellID`

Every event's `spellID` is probed *before anything touches it*, then put through a comparability
battery: `tonumber`, arithmetic, table-key round-trip, `== self`, plus `== literal`, authored-table
lookup and `string.format` as informational extras.

Readability is a **precondition, not a fourth axis**, and this is a trap worth knowing about,
because the obvious implementation gets it backwards. A secret value passes the mechanical tests
*by object identity*: `t[v] = x; t[v]` round-trips because tables hash by identity, and `v == v` is
true for the same reference. Neither means the value can be matched against the plain numeric cue
tables we author, which is the only thing the product needs. Scoring the battery alone reports
**PASS on a fully secret spellID**. The verdict therefore requires readable *and* `type == "number"`
before the battery counts.

`== literal` and `our-table lookup` returning **false is not a failure** — it just means you cast
something other than the sample id. They print dimmed and marked `(info)`.

### Supporting data

`ENCOUNTER_START` / `ENCOUNTER_END` args, `boss1`–`boss8` unit data, and `C_EncounterTimeline`
event fields are probed for secrecy and reported at the bottom, as context for the questions above.

## Install and run

```bash
cd PeaversRaidTimingsSpike
./local_deploy.sh          # copies into Interface/AddOns on macOS
```

Then `/reload` in game. You should see `PeaversRaidTimingsSpike: loaded.`

### Steps to get the answers

1. **Solo smoke test first — do not burn a raid slot debugging the addon.**
2. **`/prtspike tts`, then listen.** Path A speaks first; path B follows three seconds later. Each
   speaks a **different random word, and neither word is printed.** Type back what you heard:
   `/prtspike heard <word>`. Run it a second time if you heard both words. If you heard nothing at
   all, say so: `/prtspike heard nothing` — that is a real finding, not a failure to report one.
   Answers (A) and (B).
3. **`/prtspike forbidden`** — runs the known-forbidden control so that a *lack* of
   `ADDON_ACTION_FORBIDDEN` means something. **Expect a taint warning naming this addon; that is
   the control working.** It is reported as `provoked by the detector control (EXPECTED, excluded
   from the verdict)` and does not count against (C). Answers (C).
4. **`/prtspike oracle`** — raw `issecretvalue` / `canaccessvalue` returns. **Read the control
   lines first.** Answers (D).
5. **Run `/prtspike tts` again with the `textToSpeech` CVar OFF.** That CVar gates only the chat
   pipeline, so addon TTS *should* still fire — worth confirming rather than assuming.
6. **Go into a real raid encounter.** Nothing needs doing during the pull; capture is automatic.
   Play normally so real casts are recorded. `/prtspike` is safe to run mid-fight, and repeating it
   no longer duplicates the run in the history — a re-save **replaces** the record in place.
7. **Run `/prtspike tts` and `/prtspike oracle` during a pull too** — TTS permission and value
   secrecy can both differ in combat, and that is the state the real product runs in.
8. **On boss death the report auto-dumps** to chat and is written to the SavedVariable.
9. **`/reload` or log out** to flush `PeaversRaidTimingsSpikeDB` to disk, then read it.

### Commands

| Command | Effect |
|---|---|
| `/prtspike` | Dump the current or last run to chat, and persist it |
| `/prtspike tts` | (A)+(B) speak a random word down each TTS path |
| `/prtspike heard <word>` | Report the word you actually **heard** (or `nothing`) |
| `/prtspike forbidden` | (C) run the known-forbidden control to prove the detector works |
| `/prtspike selftest` | Prove the control cannot fabricate a (C) `FAIL` (also runs at load) |
| `/prtspike oracle` | (D) raw `issecretvalue` / `canaccessvalue` returns on real values |
| `/prtspike probe` | Re-probe boss units and the encounter timeline |
| `/prtspike save` | Persist the current run without ending it |
| `/prtspike wipe` | Clear saved results |
| `/prtspike help` | List commands |

## Reading the results

Each probed field prints as `readable` (green), `SECRET` (red), or `UNPROBEABLE` (yellow — the
probe APIs did not answer, so **nothing** may be concluded in either direction).

Each question ends in an explicit verdict line:

| Question | Verdicts |
|---|---|
| (A) | `PASS` audible (word matched) · `FAIL` blocked · `FAIL` permitted, volume/voices fine, still silent · `INCONCLUSIVE` silent but volume `0`, no voices, or we passed a non-table voice · `UNCONFIRMED` not yet reported |
| (B) | `PERMITTED for tainted code` · `ERRORED for tainted code` (with the exact failure) · `INCONCLUSIVE` API absent, our probe errored, or a fallback category was used |
| (C) | `PASS` detector proven and never named us outside the control · `FAIL` register refused, or a forbidden named us for `RegisterUnitEvent` · `INCONCLUSIVE` detector unproven/in flight, or named us for an unrelated func |
| (D) | `controls sound` · `INVALID` a control came back secret · `INCONCLUSIVE` `canaccessvalue` absent or never answered, or every control unprobeable |
| routine | `PASS` · `PARTIAL` readable but not comparable · `FAIL` secret (with the count it rests on) · `INCONCLUSIVE` no events **or** probe APIs unavailable |

**`INCONCLUSIVE` is a distinct rung from `FAIL`, on purpose.** "The probe APIs are unavailable on
this client" and "the value is secret" are different findings, and an earlier build conflated them
in *both* directions — reporting `FAIL — spellID is secret` for a perfectly readable number when
the probe APIs were merely absent, and `PARTIAL` for a value it had just printed as `SECRET`.
There is now exactly one definition of "readable" (`ProbeReadable`), used by the touch gate, the
counters and every verdict alike.

Every verdict is scored against the same two questions, because this spike is a go/no-go call and a
wrong verdict is worse than no spike:

1. **Can a control or a probe contaminate its own evidence?** (C)'s control provoked the very
   events it was scored on. (A) speaks down two paths three seconds apart, so a late utterance from
   an earlier `/prtspike tts` is now named as stale rather than scored as a mismatch, and a path
   that was never permitted to speak can no longer be recorded as "silent".
2. **Can absence of evidence print as a definite verdict?** It cannot for a missing
   `C_CombatAudioAlert`, a missing `canaccessvalue`, an unprobeable control, a muted TTS slider, or
   a detector that was never proven. Each of those is `INCONCLUSIVE`, and each is checked *before*
   the branch that would otherwise print `FAIL`.

Two consequences of that audit are worth calling out, since both silently destroyed findings:

- `/prtspike heard nothing` used to print `UNCONFIRMED`. A stored `false` was being read with the
  `x and t or nil` idiom, which collapses `false` to `nil`, so the `permitted but SILENT` branch
  was unreachable — **the one result that would sink the product could not be reported.**
- With registration refused, `/prtspike` printed `no run recorded yet. Cast a spell…` and no
  verdicts at all. A refused registration guarantees no cast ever arrives, so that advice could
  never be followed. The report now runs on an empty run so `VERDICT (C): FAIL` actually prints.

On disk the full detail lands in:

```
_retail_/WTF/Account/<ACCOUNT>/SavedVariables/PeaversRaidTimingsSpike.lua
```

`PeaversRaidTimingsSpikeDB.lastRun` is the most recent run; `.runs` keeps the last 10; `.client`
records the build so a finding can be pinned to a patch. Every run carries an `id`, and saving a
run that is already stored **replaces it in place** — so the twelve `/prtspike` calls you make
during one pull leave exactly one record, not twelve. Everything stored is a plain
string/number/boolean produced by the probe — **no raw probed value is ever persisted**, since
serialising a secret value would break the save file.

Runs saved by an older build are discarded on first load, twice over: schema `2` added the run `id`
without which a re-save cannot be deduplicated, and schema `3` added forbidden-record provenance
(`seq` / `fromControl`) without which a record provoked by the detector control is
indistinguishable from a genuine one. A run whose records cannot be attributed cannot be scored,
and scoring one anyway is exactly how (C) came out backwards. Read anything you still need before
installing this version.

## Safety properties

It runs inside live pulls, so it is built not to be able to hurt one:

- Every probe, every API call and every event handler is `pcall`-wrapped. A blocked or missing API
  degrades to a recorded `"blocked"` string, never a Lua error.
- Nothing touches a value before `issecretvalue()` / `canaccessvalue()` say it is safe. Reading a
  secret value is the failure mode being measured, not one to trigger.
- Deferred probes **capture their run** rather than reading whatever run is current when they fire.
  A fast wipe can end an encounter and start a new run before a `C_Timer.After` lands; the boss and
  timeline data still files under the encounter that requested it.
- Frames are anonymous and held in locals (NS001), so no `.wowlint.json` entry is needed.
- The cast watcher gets its own frame, separate from the encounter frame — `RegisterUnitEvent` is
  a whole-frame filtering mode, and it keeps registration findings attributable.
- The mid-encounter re-registration test and the forbidden control both use throwaway frames, so a
  refusal cannot disturb the real watcher.
- Sample counts are capped (40 casts, 40 forbidden records, 10 runs, 8 timeline events) so the save
  file stays small. The detector control scores itself off a separate **uncapped** counter — once
  40 records exist the stored table stops growing, and a control that *did* fire would otherwise
  score as if it had not, downgrading (C) to `INCONCLUSIVE` on a busy pull for no reason.

## Lint

```bash
cd PeaversRaidTimingsSpike && ../wow-api/ci/run-validation.sh
```

All three tiers must report 0.

`C_CombatAudioAlert`, `C_EncounterTimeline`, `C_UnitAuras`, `C_TTSSettings`, `C_VoiceChat`,
`TextToSpeech_Speak`, `TextToSpeech_GetSelectedVoice`, `canaccessvalue`, `UnitCastingInfo` and
`UnitClassification` all exist in the 120007 `/papidump` but are **absent from wow-api's curated
global floor**. This addon reaches them through `_G[...]` instead of referencing them directly —
lint-safe in degraded mode, and more defensive regardless, since "the API does not exist" is one of
the outcomes being measured. The real `PeaversRaidTimings` should fix the curated floor properly
rather than copy this workaround.
